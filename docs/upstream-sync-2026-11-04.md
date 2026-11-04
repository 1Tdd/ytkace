# Sincronizzazione upstream — 4 novembre 2026

Integrati gli otto commit di `itzzace/ytkace` successivi a `9127175`, fino a `bea1a28` (versione 1.1.5):

- vecchio layout Home tramite l’opzione Normal Home Layout;
- nuova gestione del watermark del canale nei nodi Elements;
- icona nativa Iscrizioni e correzioni della barra in vetro con schede senza etichetta;
- espansione della barra alla pressione quando ci sono meno schede;
- selezione e recupero della sorgente HLS, con log diagnostici aggiuntivi;
- traduzioni e versione del pacchetto aggiornate.

I conflitti nelle traduzioni sono stati risolti mantenendo le stringhe di entrambe le versioni ed eliminando ripetizioni identiche. In HLS è stata conservata la nostra esclusione degli Shorts.

Adattamenti durante l’integrazione: l’attesa HLS non blocca il thread principale; l’allineamento dell’header della versione Home è limitato a YouTube e all’opzione attiva; gli hook di calcolo dimensione e scrittura del messaggio sono abilitati insieme solo quando entrambe le firme sono compatibili.

L’intera directory `Tweak/Features/SponsorBlock` conserva il tree Git `aad9de0310c613f21ab50fd9d7f65d2fb5b90181`. Rimangono incluse tutte le correzioni dell’audit e di “Salva tutte le immagini”, documentate in `bug-audit-2026-11-04.md`.

Verifica locale: 28 test, 7 gruppi saltati per compilatore/librerie non disponibili su Windows. La pipeline IPA esegue i test completi e produce i pacchetti rootless/roothide e le IPA per iOS 16 e iOS 17+. Le prove sull’interfaccia iPhone restano necessarie per confermare il comportamento reale dei nuovi hook.
