# Afterhear · app di prova

Un'app di una sola schermata, solo per te, che risponde a quattro domande:

1. Il **tocco sull'AirPod** arriva all'app con il telefono bloccato in tasca?
2. Il **tasto Azione** fa partire l'aiuto a telefono bloccato?
3. Il **microfono in sottofondo** regge per un'ora? Quanta batteria consuma?
4. **Quanto ci mette** dal gesto al testo in italiano, e **quanto è preciso** nel rumore?

Come funziona: quando l'ascolto è attivo, l'app tiene in memoria solo gli ultimi
15 secondi. A ogni gesto prende gli ultimi 8 secondi, li trascrive (nella lingua che scegli) sul
telefono, misura il tempo, ti legge il testo nell'orecchio e salva quel momento
(solo quello) per riascoltarlo dopo. I momenti restano salvati anche se chiudi l'app:
servono per il diario (vedi sotto).

---

## Installazione (circa 15 minuti, gratis)

Serve: Mac con **Xcode 26**, iPhone con **iOS 26**, cavo USB-C.

1. **Crea il progetto.** Xcode → File → New → Project → iOS → **App**.
   - Product Name: `AfterhearTest`
   - Interface: **SwiftUI** · Language: **Swift**
   - Team: il tuo Apple ID (Xcode → Settings → Accounts → +, se non c'è)
2. **Sostituisci i file.** Nel pannello a sinistra cancella `ContentView.swift` e
   `AfterhearTestApp.swift` (Move to Trash). Poi trascina dentro la cartella
   `AfterhearTest` i 4 file `.swift` di `testapp/AfterhearTest/`: `Engine.swift`, `ContentView.swift`,
   `EncoreTestApp.swift`, `ExplainIntent.swift` (spunta "Copy items if needed").
   Se Xcode propone un "bridging header", rispondi **Don't Create**.
   Poi Build Settings → All → cerca `isolation` → **Default Actor Isolation = nonisolated**.
3. **Permessi.** Clicca il progetto (icona blu) → target `AfterhearTest` → tab **Info**
   → passa col mouse su una riga e premi **+**, aggiungi:
   - `Privacy - Microphone Usage Description` → `Serve per ascoltare le conversazioni durante il test.`
   - `Privacy - Speech Recognition Usage Description` → `Serve per trascrivere in italiano.`
4. **Audio in sottofondo.** Tab **Signing & Capabilities** → **+ Capability** →
   **Background Modes** → spunta **Audio, AirPlay, and Picture in Picture**.
5. **Sul telefono:** Impostazioni → Privacy e sicurezza → **Modalità sviluppatore** → attiva
   (il telefono si riavvia). Collega l'iPhone al Mac col cavo.
6. In alto in Xcode scegli il tuo iPhone come destinazione e premi **▶ (Run)**.
   La prima volta: sul telefono Impostazioni → Generali → VPN e gestione dispositivi →
   il tuo Apple ID → **Autorizza**. Poi di nuovo ▶.
7. **Tasto Azione:** Impostazioni → Tasto Azione → scorri fino a **Comando rapido** →
   scegli **Cosa ha detto?** (app Afterhear test).

Con l'Apple ID gratuito l'app dura **7 giorni**: poi si reinstalla con ▶.

**Se Xcode segna un errore** sulla riga `options.insert(.bluetoothHighQualityRecording)`
(in `Engine.swift`), cancella le tre righe del blocco `if #available(iOS 26.0, *) { … }`
e premi di nuovo ▶. Per qualsiasi altro errore, mandami uno screenshot.

---

## I test

Prima di ogni test: AirPods nelle orecchie, apri l'app, scegli il microfono,
**Avvia l'ascolto**, blocca il telefono e mettilo in tasca.

| # | Test | Come | Superato se |
|---|---|---|---|
| 1 | **Tocco AirPod** | Con il microfono **"Microfono AirPods"**, 20 pressioni sullo stelo (una, due, tre pressioni). Ripeti con **"Microfono iPhone"** e **"AirPods alta qualità"** | 20 su 20 in almeno una modalità. Nota in quali modalità arriva |
| 2 | **Tasto Azione** | Telefono bloccato in tasca, 20 pressioni del tasto Azione | 20 su 20 |
| 3 | **Un'ora in tasca** | Avvia, vivi normalmente per 60 minuti (cammina, bar, metro) | Nessuna interruzione non tua · batteria sotto il 10% all'ora |
| 4a | **Velocità** | Guarda "Latenza media" dopo almeno 10 gesti | Sotto i 3 secondi (3000 ms) |
| 4b | **Rumore** | 20 momenti veri: bar, tram, ufficio, negozio. A casa, ascolto fermo, tocca ogni momento per riascoltarlo e confronta col testo | Le parole importanti giuste in almeno 16 su 20 |

Alla fine premi **Esporta i risultati** e mandami il testo: decidiamo da lì.

**Cosa guardare in particolare**
- Nel test 1, la modalità conta: con il microfono degli AirPods iOS a volte non passa
  il tocco all'app. Con il microfono dell'iPhone il tocco passa più spesso, ma in tasca
  il telefono sente peggio. Il test serve proprio a capire quale compromesso regge.
- Nel test 3, se entra una chiamata o apri Spotify l'ascolto si interrompe: è normale,
  ma annotalo.
- La trascrizione qui usa il riconoscimento vocale "classico" di Apple sul telefono.
  Il nuovo di iOS 26 dovrebbe essere più veloce: se la velocità è al limite, è la prima
  cosa che cambio.


---

## Il diario dei momenti persi (test T5 · il più importante)

Serve a rispondere alla domanda su cui si regge tutto il prodotto: **quando non capisci,
quante volte è davvero una parola che non conosci?**

1. Nell'app scegli **"Lingua intorno a te"** (es. Inglese UK) prima di avviare l'ascolto.
2. Per 2 settimane, nella vita normale: ogni volta che ti sfugge qualcosa, **tasto Azione**
   (o AirPod). L'app salva gli 8 secondi.
3. **La sera**: per ogni momento premi **▶** per riascoltarlo (ad ascolto fermo), poi tocca
   **"Perché ti è sfuggito?"** e scegli la causa:
   - Parola che non conoscevo
   - Parola nota, non riconosciuta
   - Modo di dire / slang
   - Troppo veloce / accento
   - Riferimento culturale
   - Audio incomprensibile
   - Trascrizione sbagliata (l'audio era chiaro ma il testo no)
   - Falso allarme
4. Ogni tanto premi **Esporta i risultati**: in cima trovi le percentuali per causa.

**Obiettivo**: almeno 200 momenti in tutto (tu + 3–5 persone che vivono all'estero).
**Soglia**: se almeno il 60% è "parola che non conoscevo" o "modo di dire", la tesi regge.
Nota anche dove era il telefono (tasca, tavolo, AirPods): serve per il test sull'audio (T6).

Per ricominciare da zero: menu **⋯** in alto → "Cancella tutti i momenti".
