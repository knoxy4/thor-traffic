# probe-server.ps1 - a one-file status endpoint for the idle-probe test: answers every request on 127.0.0.1 with the
# current text of -BodyFile, and writes the port it got to -PortFile. run-tests.ps1 starts it and stops it.
param([string]$PortFile, [string]$BodyFile)
$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$l.Start()
[IO.File]::WriteAllText($PortFile, [string]$l.LocalEndpoint.Port)
while ($true) {
    $c = $l.AcceptTcpClient()
    try {
        $st = $c.GetStream(); $buf = New-Object byte[] 4096; [void]$st.Read($buf, 0, $buf.Length)
        $body = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($BodyFile))
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        $st.Write($head, 0, $head.Length); $st.Write($body, 0, $body.Length); $st.Flush()
    } catch {} finally { $c.Close() }
}
