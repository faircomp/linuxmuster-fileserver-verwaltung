# Anleitung: Verwaltungs-Fileserver aufsetzen

Schritt für Schritt von der leeren VM bis zur Freigabe, auf der du unter
Windows die Rechte vergibst. Die Begründungen hinter den Entscheidungen stehen
in der [README](README.md) — hier geht es nur ums Tun.

Durchgehendes Beispiel:

| | |
|---|---|
| Domäne | `linuxmuster.lan` (Workgroup `LINUXMUSTER`) |
| linuxmuster-Server (AD-DC) | `10.0.0.1` |
| Neuer Fileserver | `verwaltung01`, `10.0.0.3`, eigenes VLAN |
| Freigabe | `\\verwaltung01.linuxmuster.lan\Verwaltung` |
| Datenpfad | `/srv/samba/verwaltung` |
| Zugriffsgruppe | `verwaltung` |

Passe die Werte an. Alle Befehle laufen als `root`.

---

## Schritt 1 — VM anlegen

Eigene VM, **Ubuntu Server 24.04 LTS**. Zwei Platten: System und Daten.

Beim Ubuntu-Installer:

- **Hostname kurz halten:** `verwaltung01`. Maximal 15 Zeichen, keine Punkte.
  Das ist eine harte NetBIOS-Grenze — ein längerer Name lässt den
  Domänenbeitritt scheitern, und die Fehlermeldung sagt nicht, warum.
- **Keine Domäne eintragen.** Nur den Kurznamen.
- Datenplatte **nicht** automatisch einbinden, das kommt in Schritt 3.

```bash
hostnamectl set-hostname verwaltung01
```

`/etc/hosts` sollte den Namen enthalten:

```
127.0.1.1   verwaltung01.linuxmuster.lan   verwaltung01
```

## Schritt 2 — Netz und DNS

Der Server kommt in sein eigenes VLAN. Zwei Dinge sind zwingend:

**Der DNS-Server muss der linuxmuster-Server sein — nicht die OPNsense.**

Nur der AD-DC beantwortet die `_ldap._tcp`-SRV-Einträge, ohne die kein
Domänenbeitritt möglich ist. Die offizielle linuxmuster-Doku nennt an dieser
Stelle die Firewall-Adresse; das ist ein Fehler in der Doku und die mit Abstand
häufigste Ursache für einen scheiternden Join.

`/etc/netplan/50-cloud-init.yaml` (oder wie deine Datei heißt):

```yaml
network:
  version: 2
  ethernets:
    ens18:
      addresses: [10.0.0.3/16]
      routes:
        - to: default
          via: 10.0.0.254
      nameservers:
        addresses: [10.0.0.1]        # der linuxmuster-Server, NICHT die OPNsense
        search: [linuxmuster.lan]
```

```bash
netplan apply
```

**Firewall:** Das VLAN muss den AD-DC erreichen (Kerberos 88/464, LDAP 389/636,
SMB 445, DNS 53, NTP 123, RPC 135 und der dynamische Bereich). Umgekehrt müssen
die Verwaltungs-Arbeitsplätze auf 445 zum Fileserver kommen. Vom pädagogischen
Netz aus brauchst du keinen Zugang.

Prüfen:

```bash
ping -c1 10.0.0.1
host -t SRV _ldap._tcp.linuxmuster.lan     # muss den DC liefern
timedatectl status                          # "System clock synchronized: yes"
```

> Weicht die Uhr um mehr als 5 Minuten ab, lehnt Kerberos jedes Ticket ab.
> Ubuntu 24.04 bringt `systemd-timesyncd` mit; das genügt.

## Schritt 3 — Datenplatte einbinden

Die Rechte landen in erweiterten Attributen. Ohne die geht nichts.

```bash
mkfs.ext4 -I 512 /dev/sdb1          # größere Inodes, ACLs bleiben inline
mkdir -p /srv/samba/verwaltung
```

`/etc/fstab`:

```fstab
/dev/sdb1  /srv/samba/verwaltung  ext4  defaults,acl,user_xattr,noatime  0 2
```

```bash
mount -a
findmnt /srv/samba/verwaltung        # prüfen, dass es gemountet ist
```

Bei **ZFS** stattdessen:

```bash
zfs create -o acltype=posixacl -o xattr=sa -o dnodesize=auto tank/verwaltung
zfs set mountpoint=/srv/samba/verwaltung tank/verwaltung
```

Beides wirkt nur auf neu geschriebene Daten — vor dem Befüllen setzen.

## Schritt 4 — Zugriffsgruppe im AD anlegen

**Auf dem linuxmuster-Server**, nicht auf dem Fileserver:

```bash
sophomorix-group --create --group verwaltung
sophomorix-group --group verwaltung --addmembers sekretariat1,huber,schulleitung
sophomorix-group --group verwaltung --info        # prüfen
```

Die Mitglieder sind vorhandene Konten — auch Lehrerkonten sind in Ordnung.

> **Nicht** die WebUI unter *Kurs → Neue Gruppen* verwenden. Was dort entsteht,
> sind sophomorix-Sessions ohne AD-Objekt; die kannst du in Windows-ACLs nicht
> auswählen. Nur `sophomorix-group` und Projekte erzeugen echte AD-Gruppen.

Die Gruppe **muss existieren, bevor** du Schritt 7 ausführst.

## Schritt 5 — Server im AD registrieren

Auf dem linuxmuster-Server in
`/etc/linuxmuster/sophomorix/default-school/devices.csv` ergänzen:

```csv
server;verwaltung01;nopxe;BC:24:11:4D:97:AB;10.0.0.3;;;;server;;0;;;;VERWALTUNG;
```

15 Felder. Die Rolle `server` steht in **Feld 9**, Feld 3 ist die
Hardwareklasse (`nopxe`). Nur Feld 9 entscheidet, ob ein Computerkonto entsteht.

```bash
linuxmuster-import-devices
```

> Der Import verarbeitet immer die **gesamte** `devices.csv`. Bewusst ausführen
> und vorher sichern.

Prüfen, dass das Konto da ist:

```bash
samba-tool computer list | grep -i verwaltung01
```

## Schritt 6 — Paket installieren

Zurück auf dem **Fileserver**:

```bash
wget -qO- "https://deb.linuxmuster.net/pub.gpg" \
  | gpg --dearmour -o /usr/share/keyrings/linuxmuster.net.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/linuxmuster.net.gpg] https://deb.linuxmuster.net/ lmn73 main" \
  > /etc/apt/sources.list.d/lmn73.list

apt update
```

Das `.deb` aus den GitHub-Releases holen und installieren:

```bash
apt install ./linuxmuster-fileserver-verwaltung_7.3.0_all.deb
```

Bei der Kerberos-Abfrage des Installers **den Realm leer lassen** — `setup`
schreibt die `krb5.conf` gleich selbst.

## Schritt 7 — Setup ausführen

```bash
linuxmuster-fileserver-verwaltung setup \
    --domain linuxmuster.lan \
    --username global-admin \
    --share Verwaltung \
    --path /srv/samba/verwaltung \
    --group verwaltung \
    --folder Sekretariat \
    --folder Schulleitung \
    --folder Personal
```

Das Passwort wird abgefragt. Die Ausgabe hakt jeden Schritt ab; beim ersten
Fehler bricht es mit einer Erklärung ab, statt halb fertig weiterzulaufen.

Was passiert: Vorabprüfungen (Hostname, DNS, DC erreichbar, Zeit) →
Konfigurationsdateien schreiben → `net ads join` → Dienste starten → Gruppe
auflösen → Verzeichnis anlegen → Freigabe in der Samba-Registry → restriktive
Start-ACL → `SeDiskOperatorPrivilege` → Konfiguration mit den Gruppen-SIDs
sichern.

## Schritt 8 — Prüfen

```bash
linuxmuster-fileserver-verwaltung status
linuxmuster-fileserver-verwaltung show
```

`status` muss überall grün sein und mit Exit-Code 0 enden. Zusätzlich von Hand:

```bash
net ads testjoin                              # "Join is OK"
wbinfo --ping-dc
wbinfo --name-to-sid 'LINUXMUSTER\verwaltung'
smbclient -L localhost -U global-admin        # Freigabe muss auftauchen
```

Wenn hier etwas klemmt: Abschnitt 9 der README hat die Fehlertabelle.

## Schritt 9 — Rechte unter Windows vergeben

Das ist der eigentliche Zweck. Melde dich an einem Windows-Client als Mitglied
der **Domänen-Admins** an.

### 9.1 Verbindung herstellen

`Win+R` → `compmgmt.msc` → **Aktion → Verbindung mit anderem Computer
herstellen** → `verwaltung01` → OK.

Dann **System → Freigegebene Ordner → Freigaben**. Dort steht `Verwaltung`.

### 9.2 Freigabeberechtigung in Ruhe lassen

Rechtsklick auf `Verwaltung` → Eigenschaften → Reiter
**Freigabeberechtigungen**. Hier **nichts einschränken**.

Es gibt zwei unabhängige Ebenen, und der effektive Zugriff ist die Schnittmenge.
Wenn du auf beiden Ebenen einschränkst, entstehen die klassischen „die Rechte
stimmen doch, warum kann ich nicht schreiben"-Fälle, weil die Freigabeebene
stumm deckelt. Regle **alles** im Sicherheitsreiter.

### 9.3 Rechte auf der Wurzel setzen

Reiter **Sicherheit → Erweitert**:

1. **Vererbung deaktivieren** → *In explizite Berechtigungen konvertieren*
2. Einträge so setzen (jeweils „Diesen Ordner, Unterordner und Dateien"):

| Prinzipal | Rechte |
|---|---|
| `NT-AUTORITÄT\SYSTEM` | Vollzugriff |
| `LINUXMUSTER\Domain Admins` | Vollzugriff |
| `LINUXMUSTER\verwaltung` | Ändern |

3. Häkchen **„Alle Berechtigungseinträge für untergeordnete Objekte durch
   vererbbare Berechtigungseinträge von diesem Objekt ersetzen"** → OK

Eine restriktive Start-ACL hat `setup` bereits gesetzt; hier bestätigst und
verfeinerst du sie.

### 9.4 Ordner anlegen und differenzieren

Ab jetzt ganz normaler Windows-Alltag. Öffne `\\verwaltung01\Verwaltung` im
Explorer und arbeite wie auf jedem Windows-Fileserver.

Beispielstruktur:

```
Verwaltung\
├── Sekretariat\      nur Sekretariat: Ändern
├── Schulleitung\     nur Schulleitung: Ändern
├── Personal\         nur Schulleitung: Ändern    (Personalakten)
└── Austausch\        alle aus "verwaltung": Ändern
```

Für einen Ordner, der enger sein soll als die Wurzel:

1. Rechtsklick → Eigenschaften → Sicherheit → Erweitert
2. **Vererbung deaktivieren** → *In explizite Berechtigungen konvertieren*
3. Die Gruppe entfernen, die nicht hinein soll
4. Die berechtigte Gruppe hinzufügen

> Nutze **Verweigern**-Einträge nur, wenn es nicht anders geht. Sie gewinnen
> immer und machen Rechtestrukturen schwer nachvollziehbar. Meist ist
> „Vererbung aus, Gruppe weglassen" die sauberere Lösung.

Weil die Freigabe mit `hide unreadable = yes` läuft, sehen Benutzer nur die
Ordner, auf die sie tatsächlich Rechte haben. Das ist gewollt.

### 9.5 Delegation an eine eigene Admin-Gruppe (optional)

Wenn nicht nur Domänen-Admins die Rechte pflegen sollen:

```bash
# auf dem Fileserver
net rpc rights grant "LINUXMUSTER\fileserver-admins" SeDiskOperatorPrivilege -U global-admin
```

Domänen-Admins brauchen das nicht — sie erben es. Das Recht gilt nur lokal auf
diesem Server.

## Schritt 10 — Backup und Überwachung

### Backup

Erweiterte Attribute **müssen** mit. Fehlen sie, sind die Rechte weg, und zwar
stillschweigend.

```bash
rsync -aAX --numeric-ids --delete /srv/samba/verwaltung/ /backup/verwaltung/
```

Zusätzlich diese Dateien sichern:

```
/var/lib/samba/registry.tdb            Freigabe-Definition
/var/lib/samba/share_info.tdb          Freigabeberechtigungen
/var/lib/samba/private/secrets.tdb     Domänenbeitritt
/etc/krb5.keytab
/etc/samba/smb.conf
/etc/samba/user.map
/etc/linuxmuster-fileserver-verwaltung/share.conf
```

Und die Rechte separat als SDDL:

```bash
linuxmuster-fileserver-verwaltung save-acl -f /root/verwaltung-acl.sddl
```

### Überwachung

Windows-ACLs zeigen auf **SIDs**. Wird die Gruppe `verwaltung` gelöscht und neu
angelegt, hat sie eine neue SID — die Rechte greifen nicht mehr, und in jedem
Dialog sieht alles normal aus. `status` erkennt genau das:

```cron
7 6 * * *  root  /usr/bin/linuxmuster-fileserver-verwaltung status >/dev/null || \
                 echo "Verwaltungsfreigabe pruefen" | mail -s "Fileserver Verwaltung" admin@schule.de
```

Im Ernstfall:

```bash
linuxmuster-fileserver-verwaltung repair-acls
```

Das setzt die Basis-ACL neu. Rechte auf Unterordnern musst du unter Windows
nachziehen — bewusst, denn ein rekursives Überschreiben würde genau die
Ordnerrechte zerstören, die du in Schritt 9.4 vergeben hast.

---

## Checkliste

- [ ] Hostname ≤ 15 Zeichen, ohne Punkt
- [ ] DNS zeigt auf den linuxmuster-Server, nicht auf die OPNsense
- [ ] Zeit synchron
- [ ] Datenplatte mit `acl,user_xattr` gemountet
- [ ] Gruppe `verwaltung` mit `sophomorix-group` angelegt und befüllt
- [ ] Server in `devices.csv`, `linuxmuster-import-devices` gelaufen
- [ ] `setup` fehlerfrei durchgelaufen
- [ ] `status` grün
- [ ] Rechte in Windows gesetzt, mit einem Testkonto gegengeprüft
- [ ] Backup inklusive xattrs eingerichtet und **ein Restore getestet**
- [ ] Cron-Überwachung aktiv

## Häufige Fehler

| Symptom | Ursache |
|---|---|
| Join scheitert | DNS zeigt nicht auf den DC (Schritt 2) |
| Join scheitert | Hostname zu lang, oder Zeitversatz > 5 Min |
| Join scheitert | Server fehlt in `devices.csv` |
| Gruppe nicht auflösbar | `sophomorix-group` vergessen, oder als WebUI-„Gruppe" statt AD-Gruppe angelegt |
| Rechte nach Restore weg | Backup ohne `-X` (xattrs) |
| Alle ausgesperrt, Gruppe existiert | Gruppe neu angelegt → neue SID → `repair-acls` |
| Benutzer sieht Ordner nicht | Kein Recht → `hide unreadable` blendet aus. Gewollt. |

Wenn du dich komplett aussperrst, kommt root lokal wieder heran:

```bash
setfattr -x security.NTACL /srv/samba/verwaltung
```

Danach greift der Fallback und du kannst die Rechte neu setzen.
