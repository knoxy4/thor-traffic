# probe-server.ps1 - a one-file status endpoint for the idle-probe test: answers every request on 127.0.0.1 with the
# current text of -BodyFile, and writes the port it got to -PortFile. With -SaveFile it also keeps each request it got (the
# webhook test). run-tests.ps1 and quiet-wait-tests.ps1 start it and stop it.
param([string]$PortFile, [string]$BodyFile, [string]$SaveFile = '')
$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$l.Start()
[IO.File]::WriteAllText($PortFile, [string]$l.LocalEndpoint.Port)
while ($true) {
    $c = $l.AcceptTcpClient()
    try {
        $st = $c.GetStream(); $st.ReadTimeout = 2000; $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 4096; $t = ''
        while ($true) {
            $r = $st.Read($buf, 0, $buf.Length); if ($r -le 0) { break }; $ms.Write($buf, 0, $r)
            $t = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $he = $t.IndexOf("`r`n`r`n")
            if ($he -ge 0) { $cl = if ($t -match '(?i)content-length:\s*(\d+)') { [int]$Matches[1] } else { 0 }; if ($ms.Length - $he - 4 -ge $cl) { break } }
        }
        if ($SaveFile) { [IO.File]::AppendAllText($SaveFile, $t + "`n=====`n") }
        $body = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($BodyFile))
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        $st.Write($head, 0, $head.Length); $st.Write($body, 0, $body.Length); $st.Flush()
    } catch {} finally { $c.Close() }
}
