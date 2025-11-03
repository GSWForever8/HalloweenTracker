/*
 * ESP32 (NodeMCU-32S) Integrated Sketch (Provisioning + iBeacon + LED control) — NimBLE-Arduino compatible
 *
 * - NeoPixel LEDs are ALWAYS ON (color depends on proximity state pushed by iPhone)
 * - iBeacon advertising with fixed UUID; app controls major/minor
 * - MSB of iBeacon "minor" encodes sendHome flag (1 = child requests pickup)
 * - BLE GATT service:
 *      - CHAR_RD_ID (READ):    current {major,minor,txp}
 *      - CHAR_WR_ID (WRITE):   set {major,minor[,txp]}
 *      - CHAR_LED_CTRL (WRITE):1 byte (0=NEAR blue, 1=FAR red)
 * - NVS persistence of major/minor/txp
 * - Wi-Fi AP just to make discovery easy (optional)
 */

#include <Adafruit_NeoPixel.h>
#include <WiFi.h>
#include <NimBLEDevice.h>
#include <Preferences.h>

// Forward-declare possible signature types (pointer only is fine)
struct ble_gap_conn_desc;
class NimBLEConnInfo;

// --------------------- Pins / UI ---------------------
#define LED_PIN     23
#define BUTTON_PIN  22
#define NUM_LEDS    4

#ifndef BOOT_BTN
#define BOOT_BTN 0 // NodeMCU-32S/ESP32 "BOOT" is typically GPIO0
#endif

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);

volatile bool onlineState = true;    // not used for animation anymore; kept for future
int lastButton = HIGH;               // with INPUT_PULLUP, idle = HIGH
unsigned long lastChangeMs = 0;      // debounce timer
const unsigned long debounceMs = 40; // small debounce
volatile bool sendHome = true;       // toggled by button

// --------------------- Wi-Fi AP (optional) -----------
const char* AP_SSID     = "THIS IS AN ESP32 SUPERMINI";
const char* AP_PASSWORD = "esp32s_are_Goated";

// --------------------- iBeacon / GATT ----------------

// Fixed product UUID (16 bytes)
static const uint8_t BEACON_UUID[16] = {
  0xE2,0xC5,0x6D,0xB5,0xDF,0xFB,0x48,0xD2,0xB0,0x60,0xD0,0xF5,0xA7,0x10,0x96,0xE0
};

// Defaults (unprovisioned)
static const uint16_t DEFAULT_MAJOR = 0;
static const uint16_t DEFAULT_MINOR = 0;
static const int8_t   DEFAULT_TXPWR = -59;

// GATT UUIDs (proprietary)
static const char* SVC_UUID      = "8E400001-7786-43CA-8000-000000000001";
static const char* CHAR_RD_ID    = "8E400002-7786-43CA-8000-000000000002"; // READ {major,minor,txp}
static const char* CHAR_WR_ID    = "8E400003-7786-43CA-8000-000000000003"; // WRITE {major,minor[,txp]}
static const char* CHAR_LED_CTRL = "8E400004-7786-43CA-8000-000000000004"; // WRITE 1 byte (0=near,1=far)

Preferences prefs;
NimBLEAdvertising* adv = nullptr;
NimBLECharacteristic* chRead = nullptr;

// Current config (persisted)
uint16_t g_major = DEFAULT_MAJOR;
uint16_t g_minor = DEFAULT_MINOR;
int8_t   g_txpwr = DEFAULT_TXPWR;

// --------------------- LED / Proximity state ----------
enum ProxState : uint8_t { NEAR = 0, FAR = 1 };
volatile ProxState g_prox = FAR;  // default

void fillStrip(uint8_t r, uint8_t g, uint8_t b) {
  for (int i = 0; i < NUM_LEDS; i++) strip.setPixelColor(i, r, g, b);
  strip.show();
}
void applyLedByProx() {
  // FAR = dim red, NEAR = dim blue
  if (g_prox == FAR) {
    fillStrip(16, 0, 0);
  } else {
    fillStrip(0, 0, 20);
  }
}

// --------------------- Helpers: Button ----------------
void checkButtonToggle() {
  int raw = digitalRead(BUTTON_PIN);

  // Button state changed? (with debounce)
  if (raw != lastButton && (millis() - lastChangeMs) > debounceMs) {
    lastChangeMs = millis();
    lastButton = raw;

    // Toggle only on press (LOW)
    if (raw == LOW) {
      sendHome = !sendHome;
      Serial.printf("[BTN] sendHome toggled -> %s\n", sendHome ? "true" : "false");
      // Refresh iBeacon so iOS can see updated sendHome flag
      NimBLEDevice::stopAdvertising();
      // Small delay to avoid race in some stacks
      delay(10);
      // Restart with updated encoded minor
      if (adv) {
        adv->stop();
      }
      // Re-apply current advertising mode
      // (applyAdvertisingForState will restart advertising)
      extern void applyAdvertisingForState();
      applyAdvertisingForState();
    }
  }
}

bool shouldStop() { // kept for future expansion
  checkButtonToggle();
  return !onlineState;
}

// --------------------- Helpers: NVS ------------------
void saveConfig(uint16_t major, uint16_t minor, int8_t txp) {
  prefs.begin("ibeacon", false);
  prefs.putUShort("major", major);
  prefs.putUShort("minor", minor);
  prefs.putChar("txpwr", txp);
  prefs.end();
}

void loadConfig(uint16_t& major, uint16_t& minor, int8_t& txp) {
  prefs.begin("ibeacon", true);
  major = prefs.getUShort("major", DEFAULT_MAJOR);
  minor = prefs.getUShort("minor", DEFAULT_MINOR);
  txp   = prefs.getChar("txpwr", DEFAULT_TXPWR);
  prefs.end();
}

void clearConfig() {
  prefs.begin("ibeacon", false);
  prefs.clear();
  prefs.end();
}

// --------------------- Helpers: GATT READ value ------
void setReadValue() {
  uint8_t buf[5];
  buf[0] = (g_major >> 8) & 0xFF;
  buf[1] = (g_major     ) & 0xFF;
  buf[2] = (g_minor >> 8) & 0xFF;
  buf[3] = (g_minor     ) & 0xFF;
  buf[4] = (uint8_t)g_txpwr;
  if (chRead) chRead->setValue(buf, sizeof(buf));
}

// --------------------- Advertising payload builders --
static void buildIBeaconManufacturerData(std::string& mfg, uint16_t major, uint16_t minor, int8_t txp) {
  mfg.clear();
  mfg.reserve(25);
  mfg.push_back(0x4C); mfg.push_back(0x00);  // Apple company ID (0x004C)
  mfg.push_back(0x02);                       // iBeacon type
  mfg.push_back(0x15);                       // iBeacon length
  mfg.append((const char*)BEACON_UUID, 16);  // 16-byte UUID
  mfg.push_back((major >> 8) & 0xFF);
  mfg.push_back((major     ) & 0xFF);
  mfg.push_back((minor >> 8) & 0xFF);
  mfg.push_back((minor     ) & 0xFF);
  mfg.push_back((uint8_t)txp);
}

// --------------------- Advertising “modes” ------------
void startConfigLikeAdvertising() {
  Serial.println("[ADV] CONFIG-like (connectable, includes service UUID in scan response)");

  std::string mfg;
  // Minor is not meaningful in config mode; keep stored value without sendHome bit
  buildIBeaconManufacturerData(mfg, g_major, g_minor, g_txpwr);

  NimBLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.setManufacturerData(mfg);

  NimBLEAdvertisementData scanResp;
  scanResp.setName("TrackerCfg");
  scanResp.setCompleteServices(NimBLEUUID(SVC_UUID));

  adv->stop();
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanResp);

  adv->setMinInterval(0x00A0);
  adv->setMaxInterval(0x00F0);
  adv->start();
  setReadValue();
}

void startBeaconAdvertising(uint16_t major, uint16_t minor) {
  // Encode sendHome in MSB of minor
  uint16_t minorEnc = (sendHome ? 0x8000 : 0) | (minor & 0x7FFF);

  Serial.printf("[ADV] BEACON (connectable) m=%u n=%u(enc=%u) txp=%d sendHome=%d\n",
                major, minor, minorEnc, g_txpwr, sendHome ? 1 : 0);

  std::string mfg;
  buildIBeaconManufacturerData(mfg, major, minorEnc, g_txpwr);

  NimBLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.setManufacturerData(mfg);

  NimBLEAdvertisementData scanResp;
  scanResp.setCompleteServices(NimBLEUUID(SVC_UUID)); // expose our service for CoreBluetooth
  // Optional: scanResp.setName("TrackerCfg");

  adv->stop();
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanResp);

  adv->setMinInterval(0x00A0);
  adv->setMaxInterval(0x00F0);
  adv->start();
  setReadValue();
}

void applyAdvertisingForState() {
  if (g_major == 0 && g_minor == 0) {
    startConfigLikeAdvertising();
  } else {
    startBeaconAdvertising(g_major, g_minor);
  }
}

// --------------------- GATT callbacks ----------------
class CfgWriteCB : public NimBLECharacteristicCallbacks {
public:
  void handleWrite(NimBLECharacteristic* c) {
    std::string v = c->getValue();
    Serial.printf("[GATT] onWrite size=%u raw=", (unsigned)v.size());
    for (uint8_t b : v) Serial.printf("%02X ", b);
    Serial.println();

    if (v.size() != 4 && v.size() != 5) {
      Serial.println("[GATT] Ignoring malformed write (need 4 or 5 bytes)");
      return;
    }

    const uint8_t* p = (const uint8_t*)v.data();
    uint16_t major = (p[0] << 8) | p[1];
    uint16_t minor = (p[2] << 8) | p[3];
    int8_t txp = g_txpwr;
    if (v.size() == 5) txp = (int8_t)p[4];

    g_major = major;
    g_minor = minor;
    g_txpwr = txp;

    saveConfig(g_major, g_minor, g_txpwr);

    if (adv) adv->stop();
    applyAdvertisingForState();

    Serial.printf("[GATT] Updated iBeacon: major=%u minor=%u txp=%d\n", g_major, g_minor, g_txpwr);
  }

  void onWrite(NimBLECharacteristic* c)  { handleWrite(c); }
  void onWrite(NimBLECharacteristic* c, ble_gap_conn_desc* /*desc*/)  { handleWrite(c); }
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& /*info*/)  { handleWrite(c); }
};

// LED control callback
class LedWriteCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) {
    std::string v = c->getValue();
    if (v.size() < 1) return;
    uint8_t b = v[0];
    g_prox = (b ? FAR : NEAR);
    applyLedByProx();
    Serial.printf("[GATT] LED ctrl -> %s\n", (g_prox == FAR ? "FAR" : "NEAR"));
  }
};

// --------------------- setup / loop ------------------
void setup() {
  Serial.begin(115200);
  delay(100);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(BOOT_BTN, INPUT_PULLUP);

  if (digitalRead(BOOT_BTN) == LOW) {
    clearConfig();
    Serial.println("[NVS] Factory reset: cleared iBeacon config");
    delay(400);
  }

  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  IPAddress myIP = WiFi.softAPIP();

  strip.begin();
  strip.show();
  applyLedByProx(); // LEDs ALWAYS ON

  loadConfig(g_major, g_minor, g_txpwr);
  Serial.printf("[NVS] Loaded config: major=%u minor=%u txp=%d\n", g_major, g_minor, g_txpwr);

  NimBLEDevice::init("TrackerCfg");
  NimBLEDevice::setPower(ESP_PWR_LVL_P7);
  Serial.printf("[BLE] MAC: %s\n", NimBLEDevice::getAddress().toString().c_str());

  NimBLEServer* srv = NimBLEDevice::createServer();
  NimBLEService* svc = srv->createService(SVC_UUID);

  chRead = svc->createCharacteristic(CHAR_RD_ID, NIMBLE_PROPERTY::READ);
  setReadValue();

  NimBLECharacteristic* chWrite =
      svc->createCharacteristic(CHAR_WR_ID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  chWrite->setCallbacks(new CfgWriteCB());

  // NEW: LED control characteristic (write 1 byte: 0=near, 1=far)
  NimBLECharacteristic* chLed =
      svc->createCharacteristic(CHAR_LED_CTRL, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  chLed->setCallbacks(new LedWriteCB());

  svc->start();

  adv = NimBLEDevice::getAdvertising();
  applyAdvertisingForState();
  Serial.print("[NET] AP IP: ");
  Serial.println(myIP);
  Serial.println("[INFO] Press the button to toggle sendHome (minor MSB).");
}

void loop() {
  checkButtonToggle();
  // LEDs remain on; no animation
  delay(5);

  static unsigned long lastPrint = 0;
  if (millis() - lastPrint > 1000) {
    lastPrint = millis();
    Serial.printf("[DBG] major=%u minor=%u txp=%d sendHome=%s prox=%s\n",
                  g_major, g_minor, g_txpwr,
                  sendHome ? "true" : "false",
                  g_prox == FAR ? "FAR" : "NEAR");
  }
}
