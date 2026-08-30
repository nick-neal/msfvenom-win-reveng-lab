#Requires -Version 5.1

<#
.SYNOPSIS
    A simple TCP listener for local testing, like `nc -l`.

.DESCRIPTION
    Binds a TCP socket and waits for connections. For each client it logs the
    peer address and prints whatever bytes arrive. Optionally echoes received
    data back to the sender.

    This is a passive listener for testing/debugging (checking that something
    connects, inspecting what it sends, verifying a port binds). It does NOT
    execute, interpret, or shell out to anything it receives.

    Ctrl+C stops the listener cleanly.

.PARAMETER Address
    Interface to bind. Default 127.0.0.1 (loopback only, not reachable from
    other machines). Use 0.0.0.0 to listen on all interfaces.

.PARAMETER Port
    TCP port to listen on. Default 4444.

.PARAMETER Echo
    Echo received data back to the client (simple echo server).

.PARAMETER Once
    Handle a single connection, then exit.

.EXAMPLE
    .\Start-Listener.ps1
    Listens on 127.0.0.1:4444 and prints incoming data.

.EXAMPLE
    .\Start-Listener.ps1 -Port 8080 -Echo
    Echo server on loopback:8080.

.NOTES
    Test it from another terminal:
        Test-NetConnection 127.0.0.1 -Port 4444
    or send some text:
        $c = [Net.Sockets.TcpClient]::new('127.0.0.1', 4444)
        $s = $c.GetStream(); $b = [Text.Encoding]::ASCII.GetBytes("hello`n")
        $s.Write($b, 0, $b.Length); $c.Close()
#>

[CmdletBinding()]
param(
    [string]$Address = '127.0.0.1',
    [ValidateRange(1, 65535)][int]$Port = 4444,
    [switch]$Echo,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

try {
    $ip       = [Net.IPAddress]::Parse($Address)
    $listener = [Net.Sockets.TcpListener]::new($ip, $Port)
    $listener.Start()
}
catch {
    Write-Host "Failed to bind ${Address}:${Port} - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "(Is something already listening on that port? Try: Get-NetTCPConnection -LocalPort $Port)" -ForegroundColor Yellow
    exit 1
}

Write-Host "Listening on ${Address}:${Port}  (Ctrl+C to stop)" -ForegroundColor Cyan

try {
    while ($true) {
        # Wait for a client without a hard block, so Ctrl+C stays responsive.
        while (-not $listener.Pending()) { Start-Sleep -Milliseconds 150 }

        $client = $listener.AcceptTcpClient()
        $peer   = $client.Client.RemoteEndPoint
        Write-Host "[+] Connection from $peer  $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green

        $stream = $client.GetStream()
        $buffer = [byte[]]::new(4096)

        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                Write-Host $text -NoNewline

                if ($Echo) { $stream.Write($buffer, 0, $read); $stream.Flush() }
            }
        }
        catch {
            Write-Host "`n[!] Read error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            $client.Close()
            Write-Host "`n[-] $peer disconnected" -ForegroundColor DarkGray
        }

        if ($Once) { break }
    }
}
finally {
    $listener.Stop()
    Write-Host "Listener stopped." -ForegroundColor Cyan
}