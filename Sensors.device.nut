// IMPORTS

// Temperature Humidity sensor Library
#require "HTS221.device.lib.nut:2.0.1"

// EARLY-FIRE CODE

// Drop into low-power WiFi mode
imp.setpowersave(true);

// Set the timeout policy to advanced model
server.setsendtimeoutpolicy(RETURN_ON_ERROR, WAIT_FOR_ACK, 10);

// CONSTANTS

const OPEN_LIGHT_LEVEL = 30000;
const DOOR_CHECK_TIME = 0.25;
const READING_TIME = 300;
const DOOR_OPEN_LIMIT = 20;

// GLOBALS

local thermalLoopTimer = null;
local data = null;
local tempSensor = null;
local connectedFlag = true;
local connectingFlag = false;
local getDataCount = 0;
local openTime = 0;
local openCount = 0;

// Sensor Node HAL
sensorNodeHAL <- {
    "LED_BLUE" : hardware.pinP,
    "LED_GREEN" : hardware.pinU,
    "SENSOR_I2C" : hardware.i2cAB,
    "TEMP_HUMID_I2C_ADDR" : 0xBE,
    "ACCEL_I2C_ADDR" : 0x32,
    "PRESSURE_I2C_ADDR" : 0xB8,
    "RJ12_ENABLE_PIN" : hardware.pinS,
    "ONEWIRE_BUS_UART" : hardware.uartDM,
    "RJ12_I2C" : hardware.i2cFG,
    "RJ12_UART" : hardware.uartFG,
    "WAKE_PIN" : hardware.pinW,
    "ACCEL_INT_PIN" : hardware.pinT,
    "PRESSURE_INT_PIN" : hardware.pinX,
    "TEMP_HUMID_INT_PIN" : hardware.pinE,
    "NTC_ENABLE_PIN" : hardware.pinK,
    "THERMISTER_PIN" : hardware.pinJ,
    "FTDI_UART" : hardware.uartQRPW,
    "PWR_3v3_EN" : hardware.pinY
}

// LOOP MANAGEMENT FUNCTIONS

function doorSensorLoop() {
    // Queue up the next iteration of the door-sensing loop
    imp.wakeup(DOOR_CHECK_TIME, doorSensorLoop);

    // Is the door open? Check the light level to find out
    local lightLevel = hardware.lightlevel();

    // If the measured light level is higher than the set threshold,
    // we try to connect, otherwise swe disconnect (door is closed)
    if (lightLevel > OPEN_LIGHT_LEVEL) {
        connect();
    } else {
        disconnect();
    }
}

function thermalSensorLoop() {
    // Secondary loop to repeatedly read the temperature/humidity sensor
    thermalLoopTimer = imp.wakeup(READING_TIME, thermalSensorLoop);

    // Read and store sensor data every 30s if we are disconnected
    if (!connectedFlag) getData();
}

// CONNECTION MANAGEMENT FUNCTIONS

function connect() {
    // Are we connected already? If so, bail
    if (connectedFlag) return;

    if (!connectingFlag) {
        // We are not currently trying to connect, so we do so now
        connectingFlag = true;

        if (openTime == 0) {
            // Start the open door timer
            openTime = time();

            // Set the timer on the door alert
            openCount = 1;
            imp.wakeup(DOOR_OPEN_LIMIT, doorAlert);
        }

        // Attempt to connect with a 10-second timeout (need to be quick)
        server.connect(connected, 10);
    }
}

function connected(reason) {
    // This function manages the result of attempting to connect
    // and unexpected disconnections (which should be rare since we're almost
    // never connected to the server)
    connectingFlag = false;

    if (reason != SERVER_CONNECTED) {
        // Connection attempt timed out or failed for some reason
        connectedFlag = false;
    } else {
        // We have successfully connected
        connectedFlag = true;

        // Process any stored data we have
        processData();
    }
}

function disconnect() {
    // Disconnect from the server only if we're connected
    if (!connectedFlag) return;

    // Send one last message, indicating how long the door was open
    local data = {};
    data.timestamp <- time();

    if (openTime != 0) data.openduration <- (data.timestamp - openTime);
    openTime = 0;

    agent.send("fridge.data.upload", data);

    // Now disconnect
    connectedFlag = false;
    server.disconnect();
}

// DATA MANAGEMENT FUNCTIONS

function processData() {
    // Upload the stored data, but only if there is some
    if (data.data.len() > 0) {
        // Temporarily halt the thermal sensor loop while we transfer data
        if (thermalLoopTimer != null) imp.cancelwakeup(thermalLoopTimer);
        thermalLoopTimer = null;

        // Add a timestamp to the data to be transferred...
        data.timestamp <- time();

        // ...and the registered light level...
        data.lightlevel <- hardware.lightlevel();

        // ...and the length of time to connect
        if (openTime != 0) data.connecttime <- (data.timestamp - openTime);

        // Transfer the data
        agent.send("fridge.data.upload", data);

        // Clear the data table
        resetData();

        // Restart the thermal sensor loop
        thermalSensorLoop();
    } else {
        local data = {};
        data.timestamp <- time();
        if (openTime != 0) data.connecttime <- (data.timestamp - openTime);

        // Transfer the data
        agent.send("fridge.data.upload", data);
    }
}

function getData() {
    // Get a temperature and humidity reading from the sensor
    // Typically this happens every 300s
    tempSensor.read(function(result) {
        // Each data point is an array with the following fixed-place elements:
        // 1. Timestamp
        // 2. Error message, or empty string
        // 3. Temperature reading, or null
        // 4. Humidity reading, or null
        local dataPoint = [];
        dataPoint.append(time());

        if ("error" in result) {
            // Store the error
            dataPoint.append(result.error);
        } else {
            dataPoint.append("");
            dataPoint.append(result.temperature);
            dataPoint.append(result.humidity);
        }

        data.data.append(dataPoint);
    }.bindenv(this));
}

function resetData() {
    // Clear and prepare the data table
    data = {};
    data.data <- [];
    getDataCount = 0;
}

function doorAlert() {
    if (connectedFlag) {
        // We can only issue a warning if we are connected
        local data = {};
        data.timestamp <- time();
        data.message <- format("[ALERT] Fridge door open for at least %i seconds", DOOR_OPEN_LIMIT * openCount);
        agent.send("fridge.door.alert", data);

        // Reset the timer on the door alert
        openCount += 1;
        imp.wakeup(DOOR_OPEN_LIMIT, doorAlert);
    }
}

// RUNTIME

// NOTE we start off connected so we have to disconnect after posting the log message
server.log("BPSN starting, disconnecting...");
server.disconnect();
connectedFlag = false;

// Handle unexpected disconnections (see the target function)
server.onunexpecteddisconnect(connected);

// Set up the data store
resetData();

// Set up the sensor
sensorNodeHAL.SENSOR_I2C.configure(CLOCK_SPEED_400_KHZ);
tempSensor = HTS221(sensorNodeHAL.SENSOR_I2C, sensorNodeHAL.TEMP_HUMID_I2C_ADDR);
tempSensor.setMode(HTS221_MODE.ONE_SHOT);


// Start the sensor loops
imp.wakeup(0.1, function() {
    doorSensorLoop();
    thermalSensorLoop();
});
