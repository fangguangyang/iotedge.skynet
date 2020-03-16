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
            r_timeout = 300,
            b_timeout = 300
        }
    },
    devices = {
        a = {
            attr_poll = 2000,
            ts_poll = 1000,
            unitid = 1,
            le = false,
            batch = 20,
            tags = {
                t1 = {
                    mode = 'ts'
                    fc = 3,
                    addr = 0,
                    number = 2,
                    dt = 'uint'
                    poll = 2000,
                    cov = true,
                    gain = 1,
                    offset = 0
                },
                t2 = {
                    mode = 'attr'
                    fc = 3,
                    addr = 2,
                    number = 2,
                    dt = 'float',
                    le = true,
                    gain = 2,
                    offset = 0
                },
                t3 = {
                    mode = 'attr'
                    fc = 3,
                    addr = 5,
                    number = 2,
                    dt = 'float'
                },
                t4 = {
                    mode = 'ts'
                    fc = 4,
                    addr = 0,
                    number = 2,
                    dt = 'int'
                },
                t5 = {
                    mode = 'ts'
                    fc = 1,
                    addr = 0,
                    number = 1,
                    dt = 'boolean'
                }
            }
        }
    }
}
