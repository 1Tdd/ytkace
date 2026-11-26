# Allineamento upstream del 26 novembre 2026

Integrato `itzzace/ytkace` fino a `d531945`, 33 commit dopo `dfb103e` (upstream 1.1.9). Versione del fork: 1.2.3.

- Base IPA iOS 17+: YouTube 21.47.6 (prima 21.46.3), come upstream; iOS 16 resta 21.33.6.
- Nuovo da upstream: editor della barra azioni (con le voci del menu ⋯), menu ⋯ a schermo intero modificabile, Rimuovi riassunti IA, Adatta il video attorno al notch, orientamento a schermo intero, pagina backup separata, anteprima più grande con lo scorrimento per avanzare, estensione Safari "Apri in YTKACE", log di debug più leggeri, opzione per non avviare il PiP dal miniplayer, varie correzioni (prodotti, chip filtro, Onesie, velocità tenendo premuto).
- PiP: resta l'avvio nativo del fork. Presi da upstream il blocco dal miniplayer e la regola "con il PiP di YTKACE acceso ogni video normale può andare in PiP" (account gratuiti fuori dagli USA); gli Short tengono la risposta di YouTube come prima. Nel PiP di riserva ora vengono mantenute velocità e posizione.
- Log: presa la scrittura a blocchi di upstream; la rotazione taglia ancora su un fine riga.
- Estensione Safari: upstream la compila su macOS. Il nostro job IPA gira su Ubuntu, quindi lo script ora usa il toolchain Theos quando `xcrun` non c'è.
- Corretto: gli hook del fork che nascondono i chip filtro ora rispettano il controllo di upstream sul layout a schede Home/Iscrizioni, che altrimenti poteva bloccare YouTube all'avvio.

Nulla di questo è provato su iPhone al momento del merge.
