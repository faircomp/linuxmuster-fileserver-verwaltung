# linuxmuster-fileserver-verwaltung

Ein dedizierter Fileserver für die **Schulverwaltung** in einer
linuxmuster.net-7.3-Umgebung. Er tritt der bestehenden Samba-AD bei und stellt
genau **eine Freigabe** bereit, deren Rechte vollständig **unter Windows**
vergeben werden.

Abgeleitet von [`linuxmuster-fileserver`](https://github.com/linuxmuster/linuxmuster-fileserver)
(Netzint GmbH), aber mit einem anderen Zweck — siehe unten.

---

## 1. Warum ein eigenes Paket und nicht `linuxmuster-fileserver`?

Das Originalpaket löst eine andere Aufgabe: Es lagert den **kompletten
Schul-Share einer Schule** per DFS auf einen zweiten Server aus. Alle
Home-, Klassen- und Projektverzeichnisse wandern mit, und sophomorix verwaltet
sie weiterhin — remote über SMB (`smbclient`, `smbcacls`, `smbcquotas`), gesteuert
über `msdfs proxy`.

Für eine Verwaltungsfreigabe ist das der falsche Mechanismus:

| | `linuxmuster-fileserver` | dieses Paket |
|---|---|---|
| Zweck | Schul-Share auslagern | eigenständige Verwaltungsfreigabe |
| Sharename | muss `default-school` heißen[^1] | frei wählbar (Default `Verwaltung`) |
| Verzeichnisstruktur | von sophomorix vorgegeben | frei, per Windows angelegt |
| Rechtevergabe | sophomorix aus `.ntacl`-Templates | Windows-Sicherheitsdialog |
| DFS nötig | ja | nein |
| `sophomorix-repair` | überschreibt die Rechte | fasst diesen Server nie an |
| ID-Mapping | `autorid` | `rid` (deterministisch) |

[^1]: Lukas Spitznagel (Maintainer): „Technisch wäre es möglich, die Freigabe
anders zu benennen, Linuxmuster erwartet aber in allen Scripten und Tools die
‚default-school'."

**Der entscheidende Punkt:** Weil auf diesem Server keine sophomorix-verwalteten
Daten liegen, kann niemand die Rechte hinter deinem Rücken neu schreiben. Genau
das ermöglicht die reine Windows-Verwaltung.

---

## 2. Architekturentscheidungen

Drei Festlegungen, die man kennen sollte, bevor man produktiv geht.

### 2.1 `rid` statt `autorid` oder `ad`

sophomorix legt für Benutzer und Gruppen **keine `uidNumber`/`gidNumber` im AD
an** — das ist im Quelltext von sophomorix4 nachprüfbar (`AD_user_create` in
`SophomorixSambaAD.pm` setzt weder `uidNumber` noch `posixAccount`). Damit
scheidet das `ad`-Backend mit RFC2307 aus: Es würde jeden Benutzer ohne diese
Attribute schlicht unsichtbar machen.

Das Originalpaket nutzt `autorid`. Dessen Bereiche werden bei Erstkontakt
vergeben und in `autorid.tdb` persistiert — die Zuordnung hängt also von der
Reihenfolge ab. `rid` rechnet die Unix-ID stattdessen deterministisch aus der
RID des Kontos aus, braucht keinen Zustand und liefert auf jedem Server mit
gleicher Konfiguration dieselben IDs.

Die IDs stimmen **nicht** mit denen des linuxmuster-Servers überein. Das ist
unkritisch: Rechte werden als NT-ACLs geführt, und die sind SID-basiert.

### 2.2 `acl_xattr:ignore system acls = yes`

Samba kann NT-ACLs auf zwei Arten führen:

- **Default (`no`)** — doppelte Buchführung: NT-ACL in `security.NTACL` *plus*
  eine Best-Effort-Abbildung auf POSIX-ACLs. Samba legt einen Hash der
  POSIX-ACL im NTACL-Blob ab. Ändert irgendwas die POSIX-ACL — ein `chmod`, ein
  `rsync` ohne `-A`, ein Restore — passt der Hash nicht mehr und **Samba
  verwirft die Windows-Rechte** und leitet sie aus POSIX neu ab. Das ist die
  klassische Ursache für „nach dem Backup waren die Rechte weg".
- **`yes`** — nur die NT-ACL zählt. Deny-Einträge funktionieren, granulare
  Rechte bleiben erhalten, die Hash-Falle entfällt.

Dieses Paket setzt `yes`. **Der Preis:** Die POSIX-Rechte unterhalb der Freigabe
sind absichtlich wirkungslos (0666/0777). Jeder lokale Shell-Zugang und jeder
Nicht-SMB-Zugriffspfad umginge die Rechte vollständig. Deshalb:

- `template shell = /usr/sbin/nologin` — AD-Benutzer bekommen keine Shell
- kein NFS-Export, kein FTP, kein Webserver auf diesem Verzeichnis
- lokale Konten auf diesem Server auf das Nötigste beschränken

Die Freigabewurzel selbst ist die Ausnahme, und zwar in beide Richtungen. Der
Kernel prüft den POSIX-Modus bei **jedem** Pfadbestandteil, egal was Samba
denkt — die NT-ACL wird erst danach gefragt. Deshalb gilt dort:

- **Gruppe `<DOM>\domain users`, Modus `0770`.** Wäre die Gruppe enger gesetzt,
  scheiterte jeder gewöhnliche Benutzer schon an `chdir()`, und die Freigabe
  funktionierte nur für Administratoren. Umgekehrt hält `0770` alle Konten
  draußen, die nicht in der Domäne sind.
- **Besitzer ist ein Domänenkonto**, nämlich das aus `--username`. Vor der
  ersten NT-ACL leitet Samba die Rechte aus Besitzer und SYSTEM ab; mit `root`
  als Besitzer wäre das `S-1-22-1-0`, eine lokale SID, die kein Domänenkonto
  besitzt — die allererste ACL ließe sich dann nie setzen.

`setup` stellt beides auch **nach** dem Setzen der Start-ACL wieder her, weil
`smbcacls --set` Besitzer und Gruppe des Deskriptors bis auf die POSIX-Ebene
durchschreibt.

### 2.3 Freigabe in der Samba-Registry

Die Freigabe wird mit `net conf` angelegt, nicht in die `smb.conf` geschrieben
(`registry shares = yes`). Denselben Weg nutzt linuxmuster für seine
Schul-Shares, und die Maintainer empfehlen ihn auch für eigene Freigaben.
Vorteil: kein Neustart, und die Definition überlebt jedes Neuschreiben der
`smb.conf`. **Konsequenz:** `registry.tdb` muss ins Backup.

---

## 3. Voraussetzungen

> ⛔ **Eine eigene, frische Maschine.** Weder der linuxmuster-Server noch ein
> vorhandener `linuxmuster-fileserver`. `setup` prüft das als Allererstes und
> bricht ab, bevor es etwas schreibt: Auf einem Domänencontroller würde es die
> `smb.conf` ersetzen und die Domäne zerstören, auf einem bestehenden
> Fileserver würde der Wechsel des ID-Mappings von `autorid` auf `rid` die
> Rechte der dort ausgelagerten Schuldaten unbrauchbar machen.

- Eigene VM, **Ubuntu Server 24.04 LTS** (das ist die Basis von lmn73)
- Zweite Festplatte für die Daten
- Kurzer Hostname, **maximal 15 Zeichen** (NetBIOS-Grenze) und ohne Punkt
- **DNS-Server = der linuxmuster-Server (AD-DC)** — nicht die OPNsense

> ⚠️ Der letzte Punkt ist die mit Abstand häufigste Ursache für einen
> fehlgeschlagenen Domänenbeitritt. Die offizielle Doku nennt an dieser Stelle
> die OPNsense-Adresse; das ist ein Fehler in der Doku, bestätigt von
> Holger Baumhof: *„das ist korrekt: der DNS muss immer der AD sein."*
> `setup` prüft das vorab und bricht mit einer klaren Meldung ab.

### Dateisystem

Die Daten-Partition braucht erweiterte Attribute. `security.NTACL` liegt im
`security`-Namensraum und ist auf ext4/XFS immer verfügbar; `user_xattr`
brauchst du für die DOS-Attribute.

```fstab
# ext4
/dev/mapper/vg-data  /srv/samba/verwaltung  ext4  defaults,acl,user_xattr,noatime  0 2
```

Bei **ZFS** sind zwei Properties nicht optional — ohne sie werden ACLs
stillschweigend nicht gespeichert:

```bash
zfs set acltype=posixacl xattr=sa dnodesize=auto tank/verwaltung
```

Sie wirken nur auf **neu geschriebene** Daten.

Quota ist für eine Verwaltungsfreigabe normalerweise unnötig. Falls doch
gewünscht: Die Mount-Optionen müssen **vor** dem Setup gesetzt sein.

---

## 4. Installation

### 4.1 Server im AD registrieren

Auf dem **linuxmuster-Server** in `/etc/linuxmuster/sophomorix/default-school/devices.csv`
eine Zeile ergänzen (15 Felder; die Rolle steht in Feld 9, Feld 3 ist die
Hardwareklasse):

```csv
server;verwaltung01;nopxe;BC:24:11:4D:97:AB;10.0.0.3;;;;server;;0;;;;VERWALTUNG;
```

```bash
linuxmuster-import-devices
```

> `linuxmuster-import-devices` verarbeitet immer die **gesamte** `devices.csv`.
> Bewusst ausführen.

> ⛔ **Der Eintrag ist Pflicht und muss dauerhaft bestehen bleiben.** Der
> Import ruft `sophomorix-device --sync` auf, und das löscht jedes
> Rechnerkonto im AD, zu dem keine Zeile in einer `devices.csv` existiert
> (`sophomorix-device`: *„host is not in file anymore" → `push_kill_computer`*).
> Ein nur per `net ads join` beigetretener Fileserver verliert sein Konto beim
> nächsten Importlauf. Auffällig wird das erst beim nächsten
> winbind-Reconnect — laufende Sitzungen überleben die Löschung eine Weile und
> täuschen Betrieb vor.

### 4.2 Paketquelle und Installation

```bash
wget -qO- "https://deb.linuxmuster.net/pub.gpg" \
  | gpg --dearmour -o /usr/share/keyrings/linuxmuster.net.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/linuxmuster.net.gpg] https://deb.linuxmuster.net/ lmn73 main" \
  > /etc/apt/sources.list.d/lmn73.list

apt update
apt install ./linuxmuster-fileserver-verwaltung_7.3.0_all.deb
```

Bei der Kerberos-Abfrage des Installers den **Realm leer lassen** — `setup`
schreibt die `krb5.conf` ohnehin neu.

> Anders als das Originalpaket hängt dieses nicht vom Paket `ntp` ab, sondern
> von `chrony | ntpsec | systemd-timesyncd`. Damit entfällt das
> `apt purge systemd-timesyncd` aus der offiziellen Anleitung: Auf Ubuntu 24.04
> ist `systemd-timesyncd` bereits installiert und erfüllt die Abhängigkeit.

### 4.3 Setup

```bash
linuxmuster-fileserver-verwaltung setup \
    --domain linuxmuster.lan \
    --username global-admin \
    --share Verwaltung \
    --path /srv/samba/verwaltung \
    --group verwaltung
```

Was dabei passiert:

1. Preflight: Hostname-Länge, DNS, Domänencontroller auffindbar, Zeitsync
2. `krb5.conf`, `nsswitch.conf`, `smb.conf` aus Vorlagen schreiben
   (bestehende Dateien werden als `*.lmn-orig` gesichert), `testparm` prüfen
3. `net ads join` und Keytab erzeugen
4. `smbd`, `nmbd`, `winbind` starten
5. Zugriffsgruppe auflösen — existiert sie nicht, bricht das Setup ab (eine
   Freigabe mit unbekannter Gruppe sperrt sonst *alle* aus, ohne Fehlermeldung)
6. Verzeichnis anlegen, Test auf erweiterte Attribute, Basisrechte setzen
7. Freigabe in der Registry konfigurieren
8. Restriktive Start-ACL setzen
9. `SeDiskOperatorPrivilege` vergeben
10. Konfiguration inklusive der Gruppen-SIDs nach
    `/etc/linuxmuster-fileserver-verwaltung/share.conf` schreiben (siehe 5.)

Das Passwort wird interaktiv abgefragt und nie über die Kommandozeile an die
Samba-Werkzeuge übergeben — es läuft über eine kurzlebige Datei mit `0600`,
damit es nicht in der Prozessliste steht.

Prüfen:

```bash
linuxmuster-fileserver-verwaltung status
linuxmuster-fileserver-verwaltung show
```

---

## 5. Zugriffsgruppe im AD

Die Verwaltungsfreigabe braucht eine AD-Gruppe. Alle Konten existieren bereits
(teils als Lehrerkonten) — es geht nur darum, sie zu bündeln. Die Gruppe **muss
vor dem Setup existieren**; übergib sie mit `-g`, mehrere `-g` sind erlaubt.

### Erst die Falle: „Gruppen" in der WebUI sind keine AD-Gruppen

Was die Schulkonsole unter *Kurs → Neue Gruppen* / *Meine Gruppen* anlegt, sind
sophomorix-**Sessions** — reine Benutzerlisten für den Unterricht, ohne
AD-Objekt. Die Doku unterscheidet das ausdrücklich: *„Gruppe: … hat kein
Netzlaufwerk (keine Shares) … nur eine Liste mit Benutzer für einen Kurs"*
gegenüber *„Projekt: … mit einem gemeinsamen Projektlaufwerk"*. **Nur Projekte
werden zu AD-Gruppen.**

### Empfehlung für 7.3

```bash
# auf dem linuxmuster-Server
sophomorix-group --create --group verwaltung
sophomorix-group --addmembers sekretariat1,schulleitung --group verwaltung
```

Eine mit `sophomorix-group` angelegte Gruppe trägt die `sophomorix*`-Attribute
und ist für sophomorix damit ein *eigenes* Objekt — kein Fremdkörper. Das ist
der Punkt, auf den es ankommt (siehe unten).

Für Zugriffssteuerung auf externe Dienste ist in linuxmuster eigentlich die
**Managementgruppe** vorgesehen (`sophomorix-managementgroup`), was inhaltlich
genau dieser Anwendungsfall ist. Ein WebUI dafür gibt es bis heute nicht
([webui7 #205](https://github.com/linuxmuster/linuxmuster-webui7/issues/205),
offen seit 2021), und die Doku dazu ist dünn — Zitat eines Entwicklers:
*„It is already customizable. You can create managementgroups using sophomorix
in the terminal … I can't find good documentation on this."*

### Alternativen und warum nicht

| Weg | Bewertung |
|---|---|
| **Projekt** über die WebUI (`p_<name>`, mit Schulpräfix `<schule>-p_<name>`) | Funktioniert, per Konstruktion sophomorix-sicher, und Schuladmins pflegen die Mitglieder selbst. Preis: es entsteht ein Projektverzeichnis im Schul-Share, das du nicht brauchst. Gute Wahl, wenn Selbstbedienung wichtiger ist als Kosmetik. |
| Eigene Gruppe in `OU=Custom` per `samba-tool` | **Nicht empfohlen.** Die OU existiert zwar (pro Schule und global) und kein sophomorix-Code schreibt hinein — ein reservierter Hook. Aber sophomorix erkennt seine Objekte an den `sophomorix*`-Attributen, nicht an der OU, und ob `sophomorix-check`/`-repair` Fremdobjekte anfasst, ist **nicht belegt**. |
| `OU=LMNGroups` über die API | Erst ab **7.4**, undokumentiert, kein WebUI. Für 7.3 keine Option. |

### Wichtig: Gruppen haben SIDs, und die ändern sich

Windows-ACLs referenzieren **SIDs, keine Namen**. Wird eine Gruppe gelöscht und
unter demselben Namen neu angelegt, hat sie eine **neue SID** — die ACLs zeigen
weiter auf die alte und greifen nicht mehr. In jedem Dialog sieht alles normal
aus. „Die Gruppe ist doch wieder da" heilt die Freigabe also **nicht**.

Deshalb merkt sich `setup` die SIDs in `/etc/linuxmuster-fileserver-verwaltung/share.conf`,
und `status` vergleicht sie bei jedem Lauf:

```bash
linuxmuster-fileserver-verwaltung status        # Exit-Code 1 bei Abweichung
linuxmuster-fileserver-verwaltung repair-acls   # Basis-ACL neu setzen
```

`status` eignet sich damit direkt als Cron-Job:

```cron
7 6 * * *  root  /usr/bin/linuxmuster-fileserver-verwaltung status >/dev/null || \
                 echo "Verwaltungsfreigabe: Zugriffsgruppe hat sich geaendert" | \
                 mail -s "Fileserver Verwaltung" admin@schule.de
```

`repair-acls` setzt die **Basis-ACL auf der Freigabewurzel** neu und schreibt
die SIDs fort. Es propagiert bewusst *nicht* nach unten — das würde genau die
handvergebenen Ordnerrechte zerstören, um die es hier geht. Rechte auf
Unterordnern musst du nach so einem Vorfall unter Windows nachziehen.

Nebenbei nützlich: Das **NT-Token ist transitiv**. Verschachtelte Gruppen zählen
bei Windows-ACLs mit — eine Verwaltungsgruppe darf also andere Gruppen
enthalten.

---

## 6. Rechte unter Windows vergeben

Das ist der Teil, um den es dir eigentlich geht. Zwei **unabhängige** Ebenen —
der effektive Zugriff ist die Schnittmenge:

| | Freigabeberechtigung | NTFS-/Datei-ACL |
|---|---|---|
| Geprüft | einmal beim Verbinden | bei jedem Zugriff, pro Objekt |
| Gespeichert in | `share_info.tdb` | `security.NTACL` am Objekt |
| Granularität | Vollzugriff / Ändern / Lesen | volles NT-Modell, Deny-Einträge |
| Vererbung | keine | ja (OI/CI/NP/IO) |

**Empfehlung:** Freigabeberechtigung auf `Jeder / Vollzugriff` lassen und
*alles* im Sicherheitsreiter regeln. Sonst entstehen die klassischen
„die NTFS-Rechte stimmen doch, warum kann ich nicht schreiben"-Fälle, weil die
Freigabeebene stumm deckelt.

### Vorgehen

An einem Windows-Client als Mitglied der Domänen-Admins:

1. `compmgmt.msc` → **Aktion → Verbindung mit anderem Computer herstellen** →
   `verwaltung01`
2. **System → Freigegebene Ordner → Freigaben** → `Verwaltung` → Eigenschaften
3. Reiter **Sicherheit → Erweitert**
4. Vererbung deaktivieren → in explizite Berechtigungen konvertieren
5. Einträge setzen, jeweils „Diesen Ordner, Unterordner und Dateien"

Danach legst du im Explorer die Ordner an und vergibst pro Ordner die Rechte —
ganz normal wie auf einem Windows-Fileserver. Neue Ordner erben automatisch.

### `SeDiskOperatorPrivilege`

Mitglieder der **Domänen-Admins brauchen es nicht** — sie erben es von
`BUILTIN\Administrators`. Relevant wird es, wenn du die Verwaltung an eine
eigene Gruppe delegieren willst:

```bash
net rpc rights grant "LINUXMUSTER\Fileserver-Admins" SeDiskOperatorPrivilege -U global-admin
```

Zwei Eigenheiten: Das Recht ist **lokal auf diesem Server** (nicht domänenweit)
und es erlaubt der Gruppe, Share-Kommandos als root auszuführen — also nur an
vertrauenswürdige Gruppen.

---

## 7. Backup

Ohne erweiterte Attribute im Backup sind die Rechte weg — und zwar
**stillschweigend**, weil ein fehlendes `security.NTACL` keinen Fehler erzeugt.

```bash
# -X = xattrs, -A = POSIX-ACLs, als root
rsync -aAX --numeric-ids --delete /srv/samba/verwaltung/ /backup/verwaltung/

# tar: blankes --xattrs sichert nur user.*, security.NTACL braucht --xattrs-include
tar --xattrs --xattrs-include='*' --acls --numeric-owner \
    -cf verwaltung.tar /srv/samba/verwaltung
```

Zusätzlich sichern:

| Datei | Inhalt |
|---|---|
| `/var/lib/samba/registry.tdb` | die Freigabe-Definition |
| `/var/lib/samba/share_info.tdb` | Freigabeberechtigungen |
| `/var/lib/samba/private/secrets.tdb` | Domänenbeitritt |
| `/etc/krb5.keytab` | Kerberos-Keytab |
| `/etc/samba/smb.conf` | Konfiguration |

`winbindd_idmap.tdb` ist entbehrlich — mit `rid` sind die IDs deterministisch.

Zusätzlich die NT-ACLs aller Objekte separat sichern:

```bash
linuxmuster-fileserver-verwaltung save-acl    -f /root/verwaltung-ntacl.dump
linuxmuster-fileserver-verwaltung restore-acl -f /root/verwaltung-ntacl.dump
```

Beides arbeitet auf der xattr-Ebene (`getfattr`/`setfattr`), nicht mit
`smbcacls` — dessen `--save`/`--restore`/`--recurse` gibt es in der Samba-Version
von Ubuntu 24.04 (4.19) schlicht nicht. `save-acl` bricht ab, statt eine leere
Sicherung zu hinterlassen.

**Nicht verwenden:** `cp` ohne `-a`, `scp`, GUI-Dateimanager, `unzip` — sie
verlieren xattrs. Snapshots auf Block-Ebene und `zfs send|recv` sind unkritisch.

---

## 8. Sicherheit — was dieser Aufbau leistet und was nicht

Der Server steht in einem eigenen VLAN, ist aber **Mitglied der pädagogischen
Domäne**. Daraus folgt:

- Wer **Domänen-Admin der pädagogischen Domäne** ist, kommt an die
  Verwaltungsdaten — über die ACL oder notfalls per Besitzübernahme. Das VLAN
  ändert daran nichts. Wenn die Verwaltungsdaten davor geschützt sein müssen,
  führt kein Weg an einer **eigenen, getrennten Instanz** vorbei.
- Die Position des linuxmuster-Projekts ist genau das: Das Verwaltungsnetz soll
  strikt getrennt bleiben, die Doku behandelt ausdrücklich *„ausschließlich den
  Betrieb des pädagogischen Netzes"*. Für einen Verwaltungs-Fileserver als
  Domänenmitglied gibt es keine offizielle Vorlage.
- **Multischool ist keine Alternative dafür.** Die Schulgrenze ist im Code
  nachweislich nicht durchgesetzt: `change-school` hat keine Rechteprüfung
  ([webui7 #287](https://github.com/linuxmuster/linuxmuster-webui7/issues/287)),
  und in der API fehlte das Schul-Scoping bei allen Gruppen-Schreibendpunkten
  ([linuxmuster-api #22](https://github.com/linuxmuster/linuxmuster-api/issues/22)).
  Eine zweite Schule als Verwaltungsmandant zu missbrauchen wäre also eine
  Scheinsicherheit — davon abgesehen ist das Anlegen selbst undokumentierte
  Handarbeit.
- Umgekehrt gilt: Ein separater Server im eigenen VLAN mit eigener Freigabe und
  eigenen ACLs ist deutlich besser als ein Verwaltungsordner im Schul-Share.

Das ist eine bewusste Abwägung zugunsten der Bedienbarkeit — sie sollte nur
bewusst getroffen sein.

**Lockout-Rettung:** Sollte die NT-ACL den Zugriff komplett versperren, kann
root sie lokal entfernen; danach greift `acl_xattr:default acl style = windows`
und du kannst sie neu setzen:

```bash
setfattr -x security.NTACL /srv/samba/verwaltung
```

---

## 9. Troubleshooting

| Symptom | Ursache |
|---|---|
| Join schlägt fehl | DNS zeigt nicht auf den AD-DC (siehe 3.), Hostname > 15 Zeichen, Uhr weicht > 5 Min ab, oder Server fehlt in `devices.csv` |
| `NT_STATUS_INVALID_TOKEN` bei jedem SMB-Zugriff | eine `username map`, die ein Domänenkonto auf `root` abbildet. Auf einem Mitgliedsserver bricht das den Session-Setup — Zeile entfernen |
| Windows zeigt Rechte, die niemand gesetzt hat | kein `security.NTACL` am Objekt; Fallback greift |
| Rechte nach Restore weg | Backup ohne xattrs (siehe 7.) |
| Benutzer sieht Ordner nicht | `hide unreadable = yes` — gewollt: keine ACL, kein Ordner |
| Alle ausgesperrt, Gruppe existiert aber | Gruppe wurde gelöscht und neu angelegt → neue SID (siehe 5.) |
| Zugriff bricht plötzlich weg, `net ads testjoin` schlägt fehl | Rechnerkonto vom `linuxmuster-import-devices` entfernt, weil der Server nicht in der `devices.csv` steht (siehe 4.1) |

```bash
linuxmuster-fileserver-verwaltung status       # Dienste, Join, DC, Freigabe, Gruppen-SIDs
linuxmuster-fileserver-verwaltung show         # Freigabe, Share-Rechte, NT-ACL
linuxmuster-fileserver-verwaltung repair-acls  # Basis-ACL nach Gruppenwechsel
wbinfo --ping-dc
net ads testjoin
smbcontrol all reload-config               # nach Konfigänderungen, kein Neustart nötig
```

---

## 10. Paket bauen

```bash
apt install debhelper build-essential fakeroot
make deb          # legt das .deb eine Ebene über dem Quellverzeichnis ab
```

Ein Tag `v*` löst den Release-Workflow aus: bauen auf `ubuntu-24.04`,
Installations-Smoke-Test (Paket installieren, CLI aufrufen, gerenderte
`smb.conf` mit `testparm` prüfen), dann GitHub-Release mit dem `.deb`.

---

## Lizenz und Herkunft

Eigener Code: **GPL-3.0-or-later**.

Abgeleitet von `linuxmuster-fileserver` (Netzint GmbH, Lukas Spitznagel).
Zweck, Freigabemodell, ID-Mapping und Rechtekonzept unterscheiden sich; die
Setup-CLI ist neu geschrieben. Nah am Original bleiben `krb5.conf.example`,
`nsswitch.conf.example`, `debian/rules` und das `Makefile`.

> ⚠️ **Offene Lizenzfrage.** Das Upstream-Repository enthält **keine
> LICENSE-Datei** und nennt weder in `debian/control` noch im README noch in
> einer Quelldatei eine Lizenz. Damit ist der Lizenzstatus des Originals — und
> der davon abgeleiteten Teile — ungeklärt. Vor einer öffentlichen Verbreitung
> sollte das mit Netzint GmbH geklärt oder die betroffenen Dateien durch
> eigenständige Implementierungen ersetzt werden. Details in
> [`debian/copyright`](debian/copyright).
