# WebRTC smoke test

This local-only harness creates a SIPSorcery data-channel offer, sends it through the authenticated /api/webrtc/offer endpoint, waits for ICE/DTLS/SCTP connection, and sends one pointer message.

Install the .NET 8 SDK, then run this command from the repository root:

    dotnet build .\tools\webrtc-smoke\RemoteControl.WebRtcSmoke.csproj
