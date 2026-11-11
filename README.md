# NSPZ – NSZ → NSP für iPhone

Native iOS-App (SwiftUI, iOS 26, Liquid Glass), die komprimierte Switch-Sicherungen (`.nsz`) direkt auf dem iPhone verlustfrei in `.nsp` zurückwandelt – für den eigenen Emulator.

## Features

- **Bitgenaue Umwandlung** NSZ → NSP, inkl. SHA-256-Prüfung jeder NCA (Dateiname = Hash)
- **Keine Schlüssel nötig** – die NSZ enthält die Sektionsschlüssel bereits
- **Schnell & beliebig groß**: Streaming direkt von der Quelle (keine Zwischenkopie, konstanter RAM-Verbrauch), Block-NCZ wird parallel auf allen Kernen dekomprimiert, AES-CTR hardwarebeschleunigt, Lesen/Schreiben überlappend
- **Hintergrund**: läuft per `BGContinuedProcessingTask` weiter, mit System-Fortschrittsanzeige
- **Bibliothek**: fertige NSPs liegen in *Dateien › Auf meinem iPhone › NSPZ* – teilen, umbenennen, löschen
- Warteschlange, Live-Geschwindigkeit & Restzeit, Liquid-Glass-UI, Öffnungsanimation mit Glas-Morphing
- „Öffnen in …“ aus der Dateien-App, NSZ-Dateien im App-Ordner werden automatisch vorgeschlagen

## Installieren

**Mit Mac & Xcode 26:** `NSPZ.xcodeproj` öffnen, unter *Signing & Capabilities* dein Team wählen, iPhone auswählen, ▶︎.

**Ohne Mac:** Jeder Push baut per GitHub Actions eine unsignierte IPA (Artefakt `NSPZ-unsigned-ipa`). Diese mit AltStore, SideStore oder Sideloadly signieren und installieren.

## Aufbau

```
NSPZ/                   SwiftUI-App (Views, Modelle, Design)
Packages/NSZKit/        Konverter-Kern (PFS0, NCZ, AES-CTR, zstd) + Tests
Config/Info.plist       Dokumenttypen, Dateifreigabe, Hintergrundaufgaben
```

Tests: `cd Packages/NSZKit && swift test` (macOS) – erzeugen synthetische verschlüsselte NCAs, komprimieren sie wie `nsz` (solid und block) und prüfen die Rückwandlung Byte für Byte.

Nur für eigene, legal erstellte Sicherungskopien.
