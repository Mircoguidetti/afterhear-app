# LEXALIE per Mac (versione di test)

App nella barra dei menu che ascolta l'audio del Mac (Teams, Meet, WhatsApp, FaceTime…).
Quando qualcosa ti sfugge premi **⌃⌥A** (Control + Option + A): compare un pannello con solo il pezzo che ti è sfuggito, spiegato nella tua lingua. La sera, dal **Diario**, etichetti ogni momento.

## Scaricare e installare

1. GitHub → repo `afterhear` → **Releases** → `mac-latest` → scarica `LEXALIE-mac.zip`.
2. Aprilo e trascina **LEXALIE** in **Applicazioni**.
3. Primo avvio: macOS dice che non può verificare lo sviluppatore. Vai in **Impostazioni di Sistema → Privacy e sicurezza**, in fondo premi **Apri comunque**.
4. Permessi da dare una volta:
   - **Riconoscimento vocale**: consenti.
   - **Registrazione schermo e audio di sistema**: attiva **LEXALIE**, poi dal menu premi **Riapri LEXALIE**.
5. Menu (icona onda in alto) → **Impostazioni** → inserisci il **codice tester**.

Serve macOS 13 o più recente, va su Mac Intel e Apple Silicon.

## Server (una volta sola, su Vercel)

Progetto `asaid` (Vercel) → Settings → **Environment Variables**:

| Nome | Valore |
|---|---|
| `ASAID_TESTER_CODES` | uno o più codici separati da virgola, inventati da te (es. `marco-7Kq2,anna-9Pz4`) |
| `GEMINI_API_KEY` | chiave da aistudio.google.com (livello gratuito, per iniziare) |
| `ANTHROPIC_API_KEY` | facoltativa, da console.anthropic.com (credito prepagato) |

Se c'è una sola chiave, il server usa quel fornitore qualunque cosa sia scelta nell'app.

Poi **Deployments → Redeploy**. Le chiavi restano solo su Vercel, mai nell'app.

## Cosa fa (privacy)

- Audio solo in memoria, ultimi 15 s, sovrascritti di continuo.
- Al gesto: trascrizione sul Mac, via nomi/luoghi/aziende/numeri/email, solo quel testo va al server → Claude Haiku 4.5 (o Gemini).
- Il server non salva nulla.
- Il momento resta sul Mac (`~/Library/Application Support/LEXALIE`); l'audio si cancella dopo 7 giorni.

## Build

Ogni push su `macapp/` fa partire `.github/workflows/macapp.yml`: genera il progetto con XcodeGen, compila per Intel + Apple Silicon e pubblica lo zip nella release `mac-latest`.

## Lingue (7: EN, IT, ES, FR, DE, RU, PT)

L'app parla la lingua scelta in **Impostazioni → La tua lingua** (alla prima apertura: quella del Mac, se è una delle sette, altrimenti inglese). Cambiandola, l'app propone "Riavvia ora".

Ogni parola sullo schermo sta in `macapp/l10n/t1.py` … `t5.py` (inglese + sei traduzioni). Dopo aver cambiato o aggiunto un testo nell'app:

```
python3 macapp/l10n/make.py --todo   # cosa manca
python3 macapp/l10n/make.py          # controlla e scrive LEXALIE/<lingua>.lproj
```

Se manca una traduzione, `make.py` si ferma. Un testo nuovo va scritto come `Text("…")`, `Button("…")` ecc. oppure `String(localized: "…")`.

## Impostazioni da sviluppatore (nascoste)

Tester code, Google client ID, Server e Web app non si vedono più nelle Impostazioni (03–04/10: niente cose nostre davanti ai tester). Per mostrarle sotto "Advanced", nel Terminale:

```
defaults write app.lexalie.mac developer -bool YES
```

e riapri le Impostazioni. Per nasconderle di nuovo: `-bool NO`. I valori già salvati (per esempio il tuo tester code) restano attivi anche quando sono nascosti.
