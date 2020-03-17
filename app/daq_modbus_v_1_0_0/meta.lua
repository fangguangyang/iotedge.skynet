conf = {
    transport = {
        ascii = false,
        le = false,
        timeout = 500, -- ms
        mode = 'tcp', -- 'rtu', 'rtu_tcp'
        tcp = {
            host = '',
            port = 0,
        },
        rtu = {
            port = '',
            baudrate = 19200,
            mode = 'rs232', -- 'rs485'
            databits = 8,
            parity = 'none', -- 'odd', 'even'
            stopbits = 1,
            rtscts = false, -- hardware flow control
            r_timeout = 300, -- ms
            b_timeout = 300 -- ms
        }
    }
}
