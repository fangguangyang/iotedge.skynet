conf = {
    transport = {
        ascii = false,
        le = false,
        timeout = 500, -- ms
        mode = 'tcp',
        --mode = 'rtu',
        --mode = 'rtu_tcp',
        tcp = {
            host = '192.168.1.252',
            port = 30000,
        },
        rtu = {
            port = '',
            baudrate = 19200,
            mode = 'rs232', -- 'rs485'
            databits = 8,
            parity = 'none', -- 'odd', 'even'
            stopbits = 1,
            rtscts = false -- hardware flow control
        }
    },
    devices = {
        a = {
            attr_poll = 1000,
            ts_poll = 1000,
            unitid = 1,
            le = false,
            tags = {
                a1 = {
                    mode = "ts",
                    fc = 3,
                    addr = 0,
                    number = 2,
                    dt = "int"
                },
                a2 = {
                    mode = "ctrl",
                    fc = 16,
                    addr = 2,
                    number = 2,
                    dt = "int",
                    le = true
                },
                a3 = {
                    mode = "ctrl",
                    fc = 16,
                    addr = 4,
                    number = 3,
                    dt = "string",
                    le = true
                },
                a4 = {
                    mode = "ctrl",
                    fc = 5,
                    addr = 0,
                    number = 1,
                    dt = "boolean"
                },
                a5 = {
                    mode = "ctrl",
                    fc = 6,
                    addr = 7,
                    number = 1,
                    dt = "boolean",
                    bit = 3
                },
                a6 = {
                    mode = "ctrl",
                    fc = 16,
                    addr = 8,
                    number = 2,
                    dt = "float"
                }
            }
        }
    }
}
