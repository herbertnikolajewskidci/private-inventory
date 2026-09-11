# Plattform: iOS-only, nativ (SwiftUI), Single-User, lokal-first

Zwei iPhones im Haushalt (13 Pro Max, 16 Pro); der Nutzer ist
DevOps-Engineer ohne iOS-Hintergrund, der Code wird weitgehend von
KI-Agenten geschrieben. Entscheidung: native iOS-App (SwiftUI); v1
läuft Single-User auf einem Gerät, rein lokal, ohne Backend und ohne
Sync-Code. Das Datenmodell wird trotzdem sync-fähig gehalten
(siehe ADR-0003).

Warum: Die Kernfeatures (Barcode-Scan, OCR, spätere Foto-Erkennung)
sind First-Party-iOS-Themen; Cross-Platform müsste genau sie per
Bridge nachbauen, ohne dass Android geplant ist. Swift ist streng
statisch getypt — der Compiler fängt KI-generierte Fehler ab, bevor
sie ein Nicht-iOS-Entwickler reviewen müsste. Single-User in v1
eliminiert die gesamte Sync-/Konflikt-Komplexität.

## Considered Options

- React Native/Expo (Tür offen für Android): verworfen — Scanner,
  OCR und ML sind native Themen; der Android-Wunsch ist aktuell
  spekulativ (die zweite Person soll höchstens read-only schauen).
- CloudKit-Sync ab v1: verworfen — ohne Mehrnutzer kein Mehrwert,
  nur Komplexität.

## Consequences

- Ein späterer Wechsel zu Android/Web erzwingt Neubau und eine
  andere Sync-Lösung.
- Bewusst nicht in v1, aber festgehalten: Frau mit read-only-Zugang
  (CloudKit `CKShare`), Inventur-Modus, kontinuierlicher Scan-Modus
  mit Cooldown (Alternative zum Button-Scan), On-prem-VLM-Backend
  (siehe ADR-0004).
