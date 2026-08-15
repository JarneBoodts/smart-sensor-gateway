# Smart Sensor Gateway met monitoring en automatisatie

Cloud computing opdracht — Bachelor Elektronica-ICT, VIVES Hogeschool
Academiejaar 2025-2026

**Student:** Jarne Boodts (individueel uitgevoerd)

## 1. Situering en doel

Dit project bouwt een containergebaseerde gatewayarchitectuur die sensordata verzamelt, verwerkt, opslaat, visualiseert en centraal beheert — de kerntaak van een edge-gateway zoals die in een industriële omgeving zou draaien. Concreet: een sensor (hier gesimuleerd: joystick- en knopwaarden) publiceert data via MQTT, Node-RED verwerkt en valideert die data, InfluxDB slaat ze op als tijdreeksen, en een dashboard toont zowel live waarden als historische gemiddelden. Alles draait in Docker-containers, centraal beheerd via Portainer.

## 2. Architectuur en dataflow

Het systeem bestaat uit vier services, elk in een eigen container, verbonden via een gedeeld Docker-netwerk (`gateway-net`):

| Service | Rol | Poort |
|---|---|---|
| **Mosquitto** | MQTT-broker: ontvangt en verdeelt berichten tussen publishers en subscribers | 1883 |
| **Node-RED** | Simuleert de sensor (publiceert data) én verwerkt/valideert binnenkomende data (subscribed) | 1880 |
| **InfluxDB** | Tijdreeksdatabase die de gevalideerde metingen opslaat, met ingebouwd dashboard | 8086 |
| **Portainer** | Webinterface om alle containers te monitoren en beheren | 9000 |

De dataflow verloopt in twee gescheiden Node-RED flows:

1. **"Sensor Simulatie"** — speelt de rol van de fysieke sensor. Genereert om de paar seconden willekeurige joystick- en knopwaarden en publiceert die naar MQTT. In een echte opstelling zou dit vervangen worden door een fysieke controller of microcontroller (bv. een STM32) die naar dezelfde topics publiceert — de rest van de architectuur zou ongewijzigd blijven.
2. **"Validatie"** — abonneert zich op diezelfde MQTT-topics, controleert of de binnenkomende data geldig is, en schrijft enkel correcte metingen weg naar InfluxDB.

Deze scheiding is bewust: het toont dat de verwerkingslaag (Node-RED "Validatie") volledig onafhankelijk werkt van waar de data vandaan komt — of dat nu een simulator is of een echte sensor, maakt voor de rest van het systeem geen verschil, zolang er naar dezelfde MQTT-topics gepubliceerd wordt.

## 3. Sensorcommunicatie (MQTT)

Twee actieve topics, zoals vereist door de opdracht:

- **`sensors/joystick`** — bevat `joystick_x` en `joystick_y`, gehele getallen tussen -100 en 100, gepubliceerd elke 3 seconden.
- **`sensors/buttons`** — bevat `button_pressed`, een boolean (true/false), gepubliceerd elke 2 seconden.

Beide worden als JSON-payload verstuurd, bijvoorbeeld: `{"joystick_x": 42, "joystick_y": -17, "timestamp": "2026-08-15T17:45:00.000Z"}`.

De broker (Mosquitto) draait met `allow_anonymous true`, wat betekent dat elke client zonder inloggegevens mag publiceren/abonneren — een bewuste vereenvoudiging voor een lokale ontwikkelomgeving (zie sectie 9, Beveiliging).

![Node-RED - Sensor Simulatie flow](screenshots/node-red-simulatie.png)

## 4. Verwerking van data (Node-RED)

De flow "Validatie" leest beide topics in via `mqtt in`-nodes, en verwerkt elk datatype in een eigen, zelfgeschreven function node:

**Joystick-validatie** — controleert of `joystick_x` en `joystick_y` effectief numerieke waarden zijn, en binnen het fysiek geldige bereik [-100, 100] vallen:

```javascript
const { joystick_x, joystick_y } = msg.payload;
const isValid = (v) => typeof v === 'number' && v >= -100 && v <= 100;

if (!isValid(joystick_x) || !isValid(joystick_y)) {
    node.warn('Ongeldige joystickwaarde genegeerd: ' + JSON.stringify(msg.payload));
    return null;
}
return msg;
```

Een `return null` in Node-RED stopt de doorstroom van dat bericht volledig — de meting bereikt InfluxDB dus nooit. Dit is de kern van de vereiste "enkel correcte metingen worden doorgestuurd naar de databank".

**Knop-validatie** — controleert of `button_pressed` effectief een boolean is, en berekent er een extra numeriek veld bij:

```javascript
if (typeof msg.payload.button_pressed !== 'boolean') {
    node.warn('Ongeldige knopwaarde genegeerd: ' + JSON.stringify(msg.payload));
    return null;
}
msg.payload.button_pressed_numeric = msg.payload.button_pressed ? 1 : 0;
return msg;
```

Dat extra veld `button_pressed_numeric` (0 of 1) was noodzakelijk: InfluxDB kan geen gemiddelde berekenen over boolean-waarden (`true`/`false`), enkel over getallen. Het gemiddelde van dit veld over een periode is bovendien functioneel zinvol — het geeft het percentage van de tijd dat de knop ingedrukt was (bv. 0.3 = 30% van de tijd).

![Node-RED - Validatie flow](screenshots/node-red-validatie.png)

## 5. Opslag en visualisatie

Gevalideerde data wordt weggeschreven naar InfluxDB, in bucket `sensors`, verdeeld over twee measurements: `joystick_data` en `button_data`. Elke `influxdb out`-node in Node-RED is gekoppeld via een API-token dat lokaal in InfluxDB gegenereerd werd.

Het dashboard bevat, zoals vereist:
- **Live weergave** van joystick_x, joystick_y en button_pressed (grafieken over de laatste 15 minuten, continu ververst)
- **Gemiddelde waarden over 1 uur en over 24 uur**, voor zowel de joystick (`joystick_x`) als de knop (`button_pressed_numeric`), telkens als "Single Stat"-cel

De gemiddelde-cellen gebruiken een eigen Flux-query met een vast tijdvenster (`range(start: -1h)` of `range(start: -24h)`), onafhankelijk van de algemene tijdrange-instelling van het dashboard. Dat was nodig omdat InfluxDB's globale tijdrange-knop anders alle cellen tegelijk zou laten meeschuiven, wat het net onmogelijk zou maken om een 1u- en een 24u-gemiddelde naast elkaar te tonen.

![Dashboard - live weergave en gemiddelden](screenshots/dashboard-1.png)
![Dashboard - 24u-gemiddelden](screenshots/dashboard-2.png)

## 6. Containerisatie en netwerkarchitectuur

Alle vier services zijn gedefinieerd in `docker-compose.yml` en draaien op een gemeenschappelijk, door Compose aangemaakt Docker-netwerk (`gateway-net`). Hierdoor kunnen containers elkaar bereiken via hun servicenaam als hostnaam (bv. Node-RED verbindt met de broker via `mosquitto:1883`, niet via `localhost`) — dat is de standaard-manier waarop Docker Compose interne netwerkcommunicatie regelt, zonder dat poorten van de host nodig zijn voor communicatie tussen de containers onderling.

Elke service heeft een eigen volume voor persistente data, zodat flows, dashboards en databankinhoud bewaard blijven bij een herstart:
- `node-red-data/` — Node-RED flows en credentials
- `influxdb-data/` — de eigenlijke tijdreeksdatabank
- `portainer-data/` — Portainer-configuratie
- `mosquitto/data/` en `mosquitto/log/` — broker-persistentie en logs

## 7. Monitoring en beheer (Portainer)

Portainer geeft een centraal overzicht van alle draaiende containers, hun status, poorten en resourcegebruik — precies de "monitoring en beheer"-vereiste uit de opdracht.

![Portainer - container overzicht](screenshots/portainer.png)

Alle vier containers staan op `running` of `healthy`, elk gekoppeld aan hun juiste poort.

## 8. Automatisatie (Docker Compose)

De volledige stack start met één enkel commando:

```bash
docker compose up -d
```

Dit leest `docker-compose.yml`, haalt de nodige images op (Mosquitto, Node-RED, InfluxDB, Portainer), maakt het gedeelde netwerk aan, en start alle containers in de juiste volgorde (Node-RED wacht bijvoorbeeld op Mosquitto en InfluxDB via `depends_on`).

## 9. CI/CD

Het script `deploy.sh` demonstreert de basisprincipes van CI/CD voor dit project: automatisch bijwerken van de infrastructuur zonder handmatige tussenkomst.

```bash
#!/bin/bash
set -e

echo "[1/4] Bestaande containers stoppen..."
docker compose down

echo "[2/4] Images opnieuw ophalen..."
docker compose pull

echo "[3/4] Stack opnieuw opstarten..."
docker compose up -d

echo "[4/4] Status van de containers:"
docker compose ps
```

Uitvoeren:
```bash
chmod +x deploy.sh
./deploy.sh
```

**Hoe dit zich verhoudt tot een echte pipeline:** in een productieomgeving zou dit script niet manueel uitgevoerd worden, maar automatisch getriggerd worden door een CI/CD-systeem zoals GitHub Actions, telkens er een wijziging naar de `main`-branch gepusht wordt. Zo'n pipeline zou typisch: (1) inloggen op de doelserver via SSH, (2) de laatste versie van de code pullen vanuit Git, en (3) dit `deploy.sh`-script uitvoeren om de nieuwe versie live te zetten. Voor dit project wordt datzelfde eindresultaat (stoppen → nieuwe images ophalen → herstarten) manueel gedemonstreerd, wat inhoudelijk identiek is aan wat een geautomatiseerde pipeline zou doen — enkel de trigger (een commando intypen versus een automatische Git-push) verschilt.

Als optionele uitbreiding zou een tool zoals **watchtower** dit verder automatiseren: die container zou periodiek zelf controleren op nieuwe image-versies op Docker Hub, en de betrokken containers automatisch herstarten zodra een update beschikbaar is, zonder dat iemand het script manueel moet uitvoeren.

## 10. Installatie

Vereisten: Docker Desktop met WSL2-integratie (Windows), of Docker + Docker Compose (Linux).

```bash
git clone https://github.com/JarneBoodts/smart-sensor-gateway.git
cd smart-sensor-gateway
docker compose up -d
```

Na enkele seconden (te controleren met `docker ps`) zijn de interfaces bereikbaar:
- Node-RED: http://localhost:1880
- InfluxDB: http://localhost:8086 (login: `admin` / `adminpassword`)
- Portainer: http://localhost:9000 (eigen account aanmaken bij eerste bezoek)

De Node-RED flows worden automatisch mee geladen via het `node-red-data`-volume. Eén handmatige stap is nodig bij een volledig nieuwe opzet: in InfluxDB moet via **Load Data > API Tokens** een nieuw token gegenereerd worden, dat vervolgens ingevuld moet worden in de configuratie van de `influxdb out`-nodes in de Node-RED "Validatie"-flow (dubbelklikken op de node > Server bewerken > Token-veld).

## 11. Beveiliging

- Mosquitto draait met `allow_anonymous true`, wat toegang zonder authenticatie toelaat. Dit is een bewuste keuze voor een lokale ontwikkelomgeving; voor een productie-opstelling zou een wachtwoordbestand (`mosquitto_passwd`) en/of TLS-versleuteling nodig zijn.
- Het InfluxDB API-token wordt nergens in platte tekst in de repository bewaard: het staat enkel in Node-RED's eigen, versleutelde credentials-bestand (`flows_cred.json`), en die volledige map (`node-red-data/`) is via `.gitignore` uitgesloten van Git — het token komt dus nooit publiek op GitHub terecht.
- Standaardwachtwoorden zoals dat van InfluxDB (`adminpassword`) staan momenteel rechtstreeks in `docker-compose.yml`. Voor een productie-opstelling zouden deze via een apart `.env`-bestand beheerd moeten worden (eveneens uitgesloten via `.gitignore`), zodat gevoelige waarden nooit samen met de rest van de configuratie gedeeld worden.

## 12. Reflectie en samenwerking

Dit project werd individueel uitgevoerd. Dat maakte het pittiger dan verwacht, aangezien alle onderdelen door mij opgezet en getest moesten worden zonder werk te kunnen verdelen. Door er voldoende tijd voor vrij te maken en te focussen, is het uiteindelijk toch gelukt om het project volledig af te werken.

## 13. Versiebeheer

Volledige projectcode: https://github.com/JarneBoodts/smart-sensor-gateway

Grote, automatisch gegenereerde datamappen (`node-red-data/`, `influxdb-data/`, `portainer-data/`, `mosquitto/data/`, `mosquitto/log/`) en gevoelige bestanden (`.env`) zijn via `.gitignore` uitgesloten van versiebeheer.
