# Allineamento upstream del 3 novembre 2026

Integrato `itzzace/ytkace` fino a `9127175` (Fix Extra Dim breaking rotation), mantenendo le modifiche del fork sui download, capitoli, post community e SponsorBlock.

- Base IPA iOS 17+: YouTube 21.44.4; iOS 16: 21.33.6.
- Correzioni pubblicità per 21.44.4, rotazione Extra Dim, tab bar/etichette e ripristino Iscrizioni.
- Barra di avanzamento sempre visibile, schermata finale/autoplay, sottotitoli Sempre disattivati e coda locale.
- Nuove opzioni link diretti, disattivazione feedback aptico, rimozione Ascolta con YouTube Music, pulsante rotazione del lettore download.
- Risolti i conflitti mantenendo l'ottimizzazione locale degli overlay e tutte le traduzioni aggiunte dal fork. La vecchia opzione Related Videos rimossa upstream non resta attiva nei vecchi hook.
- Conservate cache, concorrenza e pipeline multimediale del fork; aggiornato anche il fallback URL incorporato del workflow.

La cartella SponsorBlock è identica prima e dopo il merge: `aad9de0310c613f21ab50fd9d7f65d2fb5b90181`. Non sono stati aggiunti SponsorMenu né l'interfaccia SponsorBlock upstream.

L'audit prestazioni è descritto in `download-performance-audit-2026-11-03.md`; il salvataggio multiplo dei post in `community-post-images-2026-11-03.md`.
