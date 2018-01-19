utilities <- {};

utilities.dayOfWeek <- function(d, m, y) {
    local dim = [
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    ];

    local ad = ((y - 1) * 365) + _totalLeapDays(y) + d - 5;
    for (local i = 0 ; i < m ; ++i) {
        local a = dim[utilities._isLeapYear(y)];
        ad = ad + a[i];
    }
    return (ad % 7) - 1;
}

utilities.isLeapYear <- function(y) {
    if (utilities._isLeapYear(y) == 1) return true;
    return false;
}

utilities.bstCheck <- function() {
    // Checks the current date for British Summer Time,
    // returning true or false accordingly
    local n = date();
    if (n.month > 2 && n.month < 9) return true;

    if (n.month == 2) {
        // BST starts on the last Sunday of March
        for (local i = 31 ; i > 24 ; --i) {
            if (utilities.dayOfWeek(i, 2, n.year) == 0 && n.day >= i) return true;
        }
    }

    if (n.month == 9) {
        // BST ends on the last Sunday of October
        for (local i = 31 ; i > 24 ; --i) {
            if (utilities.dayOfWeek(i, 9, n.year) == 0 && n.day < i) return true;
        }
    }
    return false;
}

utilities._totalLeapDays <- function(y) {
    local t = y / 4;
    if (utilities._isLeapYear(y) == 1) t = t - 1;
    t = t - ((y / 100) - (1752 / 100)) + ((y / 400) - (1752 / 400));
    return t;
}

utilities._isLeapYear <- function(y) {
    if ((y % 400) || ((y % 100) && !(y % 4))) return 1;
    return 0;
}

utilities.timestampToIso <- function(timestamp) {
    local now = date(timestamp);
    local ts = "+00:00";
    if (utilities.bstCheck()) {
        now.hour++;
        if (now.hour > 23) now.hour = 0;
        ts = "+01:00";
    }
    return format("%i-%02i-%02i %02i:%02i:%02i %s", now.year, now.month + 1, now.day, now.hour, now.min, now.sec, ts);
}

device.on("fridge.door.alert", function(data) {
    // For now, just dump the alert to the log
    server.log("[WARNING] " + data.message + " (triggered at " + utilities.timestampToIso(data.timestamp) + ")");
});

device.on("fridge.data.upload", function(data) {
    // For now, just dump the data to the log
    if ("timestamp" in data) server.log ("Data posted by device at " + utilities.timestampToIso(data.timestamp));
    if ("openduration" in data) server.log (format("Door closed after %i seconds", data.openduration));
    if ("connecttime" in data) server.log (format("Connected to server in %i seconds", data.connecttime));
    if ("battery" in data) server.log (format("Battery voltage is %iV", data.battery));
    if ("lightlevel" in data) {
        local pc = (data.lightlevel.tofloat() / 65535.0) * 100.0;
        server.log ("Light level with door open: " + data.lightlevel + format(" (%.1f%%)", pc));
    }

    if ("data" in data) {
        local dataPoints = data.data;
        if (dataPoints.len() > 0) {

            foreach (dataPoint in dataPoints) {
                local timeString = utilities.timestampToIso(dataPoint[0]);
                if (dataPoint[1].len() > 0) {
                    server.log("Error at " + timeString + ": " + dataPoint[1]);
                } else {
                    server.log("Datapoint at " + timeString + ": " + format("temperature %0.2f°C, humidity %0.2f%s", dataPoint[2], dataPoint[3], "%"));
                }

                imp.sleep(0.5);
            }
        } else {
            server.log("But no readings were included");
        }
    }
});
