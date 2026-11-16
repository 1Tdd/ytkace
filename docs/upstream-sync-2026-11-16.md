# Allineamento upstream del 16 novembre 2026

Integrato `itzzace/ytkace` fino a `dfb103e` (Release 1.1.8), 11 commit dopo `c85f15b`. Versione del fork: 1.2.2.

- Base IPA iOS 17+: YouTube 21.46.3 (prima 21.45.4), come upstream; iOS 16 resta 21.33.6.
- Nuovo da upstream: editor per tutti i pulsanti del player (anche quelli di YouTube), pulsanti mescolati nella riga in alto e nella barra a schermo intero, colonna di pulsanti a sinistra, filtri Shorts per live e post, PiP che non parte con il video in pausa, PiP che riparte dopo uno Short, correzioni a velocità tenendo premuto, backup e titolo.
- Velocità: i pulsanti ora stanno nella nuova colonna sinistra di upstream invece che in una colonna separata del fork, così non si sovrappongono ad altri pulsanti messi a sinistra e l'editor li può spostare. Di base restano a sinistra (+ 1x - dall'alto). Una sola volta, la posizione salvata dall'editor 1.2.1 viene scartata, perché prima non aveva effetto.
- PiP: resta l'avvio nativo del fork, con in più i due fix upstream.
- Corretti: l'icona SponsorBlock del fork nell'editor; il pulsante SponsorBlock aggiungeva un riconoscitore di pressione prolungata a ogni layout del player; il filtro Shorts di upstream ora restituisce lo stesso tipo di raccolta che riceve.

Nulla di questo è provato su iPhone al momento del merge.
