conf = {
    ascii = false,
    le = false,
    timeout = 50,
    mode = 'rtu',
    --mode = 'tcp',
    --mode = 'rtu_tcp',
    tcp = {
        host = '',
        port = 1,
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
}
