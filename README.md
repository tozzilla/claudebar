# ClaudeBar

App nativa per la **barra dei menu** di macOS (Apple Silicon) che mostra gli
stessi dati di utilizzo della console Claude, in tempo reale.

```
  8% · 4h47m      ← barra dei menu: % sessione corrente · tempo al reset
```

Cliccando si apre il dettaglio, identico alla console:

- **Sessione corrente**: % utilizzato + reset (es. 17:39)
- **Limiti settimanali**: Tutti i modelli %, Sonnet % (+ altri se presenti), reset
- **Crediti extra**: spesa in € su limite mensile

## Come funziona

I dati provengono dallo stesso endpoint autenticato che usa la console Claude
(`/usage`):

1. Legge il token OAuth di Claude Code dal **Keychain** (voce
   `Claude Code-credentials`).
2. Interroga `https://api.anthropic.com/api/oauth/usage`.
3. Mostra percentuali, reset e crediti — **gli stessi numeri della console**.

> ⚠️ Le percentuali della console **non** sono ricavabili dai log locali
> (`~/.claude/projects/*.jsonl`): quelli contengono solo i conteggi di token.
> Strumenti tipo `ccusage` stimano dai token e perciò **non combaciano** con la
> console. ClaudeBar legge invece il dato ufficiale.

Il token viene riletto dal Keychain a ogni aggiornamento, quindi resta valido
finché usi Claude Code (che lo rinnova). Se scade, l'app mostra
`⚠︎ login` e basta riaprire Claude Code.

Zero dipendenze: singolo binario Swift nativo arm64.

## Primo avvio: permesso Keychain

Al primo accesso macOS può chiedere il permesso di leggere
`Claude Code-credentials`. Clicca **"Consenti sempre"**. Da quel momento l'app
legge il token senza ulteriori richieste.

## Uso

```bash
./init.sh            # build + avvio (sviluppo, in foreground)
./build.sh           # crea ClaudeBar.app (bundle standalone)
open ClaudeBar.app   # avvia l'app
```

Installazione stabile:

```bash
./build.sh
cp -r ClaudeBar.app /Applications/
open /Applications/ClaudeBar.app
```

Poi dal menu dell'app: **Avvia al login**.

### Debug

```bash
.build/release/ClaudeBar --print   # stampa lo snapshot corrente ed esce
```

## Personalizzazione

- **Intervallo di aggiornamento**: timer in `AppDelegate.swift` (default 60s —
  l'endpoint si aggiorna circa ogni minuto).
- **Testo in barra**: `updateTitle(_:)` in `AppDelegate.swift`.

## Requisiti

- macOS 13+ (Apple Silicon)
- Swift toolchain (Command Line Tools bastano — `swift --version`)
- Claude Code installato e loggato (per il token nel Keychain)
