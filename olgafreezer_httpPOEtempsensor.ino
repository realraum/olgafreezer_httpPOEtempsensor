#include <Arduino.h>
#include <avr/eeprom.h>
#include <avr/wdt.h>
#include <SPI.h>         // needed for Arduino versions later than 0018
#include <UIPEthernet.h>
// the sensor communicates using 1W, so include the library:
#include <OneWire.h>
#define lcd_20X4 // Define this if you have a 20 X 4 display.
#include <LiquidCrystal.h>
#include <BigCrystal.h>

/*
 * running on a Seeduino
 * programm as Genuino UNO
 * 
^ PIN ^ Function       ^
|  13 | Ethernet / SPI |
|  12 | Ethernet / SPI |
|  11 | Ethernet / SPI |
|  10 | Ethernet / SPI |
|  9  | Onewire Temp Sensors DQ |
|  8  | NPN Transistor controlling Alarm Sound |
|  0  | Serial RX, Shared with FTDI |
|  1  | Serial TX, Shared with FTDI |
|  2  | Mute Button, connected via Button to GND |
|  A5  | HD47780 Pin 14 |
|  A4  | HD47780 Pin 13 |
|  A3  | HD47780 Pin 12 |
|  A2  | HD47780 Pin 11 |
|  A1  | HD47780 Pin  6 |
|  A0  | HD47780 Pin  4 |
*/

#define PIN_BELL 8
#define QBUF_LEN 96
#define PIN_MUTEBUTTON 2

//LiquidCrystal lcd(7, 6, 5, 4, 3, 2);
LiquidCrystal llcd(A0, A1, A2, A3, A4, A5);
BigCrystal lcd(&llcd);

// assign a MAC address for the ethernet controller.
// fill in your address here:
byte mac[] = {0x62,0xac,0x2e,0x6d,0x81,0x12};


// Initialize the Ethernet server library
// with the IP address and port you want to use 
// (port 80 is default for HTTP):
EthernetServer server(80);


OneWire  ds(9);  // on pin 10 (a 4.7K resistor is necessary)

#define MAX_TEMP_SENSORS 3
#define EEPROM_CURRENT_VERSION 3
#define EEPROM_ADDR_VERS 0
#define EEPROM_ADDR_BELLMUTEDUR 1
#define EEPROM_ADDR_IP1 2
#define EEPROM_ADDR_IP2 3
#define EEPROM_ADDR_IP3 4
#define EEPROM_ADDR_IP4 5
#define EEPROM_ADDR_GW1 6
#define EEPROM_ADDR_GW2 7
#define EEPROM_ADDR_GW3 8
#define EEPROM_ADDR_GW4 9
#define EEPROM_ADDR_SUBNET1 10
#define EEPROM_ADDR_SUBNET2 11
#define EEPROM_ADDR_SUBNET3 12
#define EEPROM_ADDR_SUBNET4 13
// EEPROM_ADDR_WARN has variable size so needs to be last!!!
#define EEPROM_ADDR_WARN 14

#define TEMP_INVALID -9999
#define TEMPWARN_OFF 9999

volatile uint8_t mute_counter_ = 0;
uint8_t bell_std_mute_duration_ = 45;
float temperature[MAX_TEMP_SENSORS] = {TEMP_INVALID, TEMP_INVALID, TEMP_INVALID};
float warnabove_threshold[MAX_TEMP_SENSORS] = {TEMPWARN_OFF, TEMPWARN_OFF, TEMPWARN_OFF};
char const *sensornames[MAX_TEMP_SENSORS] = {"OLGA freezer","Outside", "OLGA room"};
uint8_t temp_sensor_id = -1;
long lastReadingTime = 0;
byte readingMode = 0;
uint8_t bellbangcount = 0;
#define BELL_ALARM 0
#define BELL_FORCEOFF -1
#define BELL_FORCEON 1
volatile int8_t bellMode_ = 0;
float warnabove_threshold_complement[MAX_TEMP_SENSORS];


char *ftoa(char *a, double f, int precision)
{
 long p[] = {0,10,100,1000,10000,100000,1000000,10000000,100000000};
 
 char *ret = a;
 long heiltal = (long)f;
 itoa(heiltal, a, 10);
 while (*a != '\0') a++;
 *a++ = '.';
 long desimal = abs((long)((f - heiltal) * p[precision]));
 itoa(desimal, a, 10);
 return ret;
}

void RESET(void)
{
  wdt_enable(WDTO_15MS);
  while(1);
}

void eeprom_update_block (const void *__src, void *__dst, size_t __n)
{
  byte testbyte;
  uint8_t *_myDstPtr       =       (uint8_t *)__dst;
  uint8_t *_mySrcPtr       =       (uint8_t *)__src;  
  while (__n--)
  {
    testbyte = eeprom_read_byte(_myDstPtr);
    if (testbyte != *_mySrcPtr)
      eeprom_write_byte(_myDstPtr, *_mySrcPtr);
    _myDstPtr++, _mySrcPtr++;
  }
}

union bitfloat {
  float f;
  uint32_t i;
};

void complementFloat(float *ptr1, float *complement)
{
  uint32_t complement32 = 0xffffffff ^ ((bitfloat*)ptr1)->i;
  *complement = ((bitfloat*) &complement32)->f;
}

void complementCheckFloat(float *ptr1, float *complement)
{
  uint32_t checksum = ((bitfloat*)ptr1)->i ^ ((bitfloat*)complement)->i ^ 0xffffffff;
  if ( checksum > 0 )
  {
      RESET();
  }
}

void muteButtonPressed()
{
  bellMode_ = BELL_ALARM;
  if (mute_counter_ == 0) {
    mute_counter_ = bell_std_mute_duration_;
    digitalWrite(PIN_BELL, LOW);
  }
  lcd.clear();
  lcd.print(F("Mute Button Pressed"));
}

void setup() {
  // initalize the  data ready and chip select pins: 
  pinMode(PIN_BELL, OUTPUT);
  digitalWrite(PIN_BELL, LOW);
  pinMode(PIN_MUTEBUTTON, INPUT);
  digitalWrite(PIN_MUTEBUTTON, HIGH); //pullup

  Serial.begin(9600);
  Serial.setTimeout(100); //import for strings to come in all at once

  if (eeprom_read_byte(EEPROM_ADDR_VERS) == EEPROM_CURRENT_VERSION) {
    bell_std_mute_duration_ = (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_BELLMUTEDUR);
    eeprom_read_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
  } else {
    eeprom_write_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_BELLMUTEDUR, bell_std_mute_duration_);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_IP1, 192);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_IP2, 168);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_IP3, 127);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_IP4, 244);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_GW1, 192);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_GW2, 168);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_GW3, 127);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_GW4, 254);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_SUBNET1, 255);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_SUBNET2, 255);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_SUBNET3, 255);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_SUBNET4, 0);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_VERS, EEPROM_CURRENT_VERSION);
  }
  for (uint8_t c=0; c<MAX_TEMP_SENSORS; c++)
    complementFloat(&warnabove_threshold[c], &warnabove_threshold_complement[c]);

  oneWireSearchAndStartConversion();

  // assign an IP address for the controller:
  IPAddress ip((uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_IP1),
               (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_IP2),
               (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_IP3),
               (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_IP4));
  IPAddress gateway((uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_GW1),
                    (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_GW2),
                    (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_GW3),
                    (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_GW4));
  IPAddress subnet((uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_SUBNET1),
                   (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_SUBNET2),
                   (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_SUBNET3),
                   (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_SUBNET4));
  // start the Ethernet connection and the server:
  Ethernet.begin(mac, ip, gateway, subnet);
  server.begin();

  lcd.begin(20, 4);
  lcd.clear();
  lcd.print(F("OLGA Freezer        "));
  lcd.print(F("(c) 2015            "));
  lcd.print(F("         Temp Sensor"));
  lcd.print(F(" Bernhard Tittelbach"));

  // give the sensor and Ethernet shield time to set up:
  delay(3000);

  //attachInterrupt(digitalPinToInterrupt(PIN_MUTEBUTTON), muteButtonPressed, FALLING);
  attachInterrupt(0, muteButtonPressed, FALLING);  //PIN2 should be Interrupt 0

  //init_big_font(&lcd);
  wdt_enable(WDTO_4S); //enable watchdog, reset if dog was not patted after 4seconds
}

void loop() { 
  // check for a reading no more than once a second.
  if (millis() - lastReadingTime > 1000) {
    if (readingMode == 0) {
      readingMode = oneWireSearchAndStartConversion();
    } else {
      getData();
      readingMode = 0;
      checkTempAndWarn();
      displayTempOnLCD();
    }
    lastReadingTime = millis();
  }
  wdt_reset(); //pat the dog

  //check for integrity of variables
  for (uint8_t c=0; c<MAX_TEMP_SENSORS; c++)
    complementCheckFloat(&warnabove_threshold[c], &warnabove_threshold_complement[c]);

  // listen for incoming Ethernet connections:
  listenForEthernetClients();
  serialReadConfigureIP();
}

//update network config:
//echo -n ip:\xXX\xXX\xXX\xXX. > /dev/ttyUSB0
//echo -n gw:\xXX\xXX\xXX\xXX. > /dev/ttyUSB0
//echo -n nm:\xXX\xXX\xXX\xXX. > /dev/ttyUSB0
void serialReadConfigureIP() {
  uint8_t serbuff[4] = {0,0,0,0};
  if (!Serial.available())
    return;
  uint8_t n = Serial.readBytesUntil(':', (char*) serbuff, 3);
  void* targetaddr = 0;
  if (n == 3 && strncmp((char*) serbuff, "ip:", 3) == 0)
  {
    targetaddr = (void*) EEPROM_ADDR_IP1;
  } else if (n == 3 && strncmp((char*) serbuff, "gw:", 3) == 0)
  {
    targetaddr = (void*) EEPROM_ADDR_GW1;
  } else if (n == 3 && strncmp((char*) serbuff, "nm:", 3) == 0)
  {
    targetaddr = (void*) EEPROM_ADDR_SUBNET1;
  } else if (n == 3 && strncmp((char*) serbuff, "rs:", 3) == 0)
  {
    RESET();
  }
  if (!Serial.available())
    return;
  if (targetaddr == 0)
    return;
  n = Serial.readBytes((char*) serbuff,4);
  if (n == 4 && Serial.available() && Serial.read() == '.') {
    eeprom_update_block((void*)serbuff, targetaddr, 4);
  }
}

void checkTempAndWarn() {
  bool warn=false;

  if (bellMode_ == BELL_FORCEON)
    warn=true;
  else if (bellMode_ == BELL_FORCEOFF)
    warn=false;
  else for (uint8_t tid=0; tid < MAX_TEMP_SENSORS; tid++) {
    if (temperature[tid] != TEMP_INVALID && temperature[tid] > warnabove_threshold[tid])
      warn=true;
  }

  if (warn)
  {
    if (mute_counter_ > 0)
    {
      digitalWrite(PIN_BELL, LOW);
      mute_counter_--;
    } else {
      //make some non-continous sound
      //digitalWrite(PIN_BELL, HIGH);
      digitalWrite(PIN_BELL, not digitalRead(PIN_BELL));
    }
  } else {
    digitalWrite(PIN_BELL, LOW);
    mute_counter_ = 0;
  }
}

void displayTempOnLCD() {
  char tmp[6];
  if (temp_sensor_id >= MAX_TEMP_SENSORS)
    return;

  if (temperature[temp_sensor_id] < 0)
    ftoa(tmp,temperature[temp_sensor_id],1); //leave space for minus
  else
    ftoa(tmp,temperature[temp_sensor_id],2);
  tmp[5] = 0;
  lcd.clear();
  lcd.print(temp_sensor_id);
  lcd.print(F(":"));
  lcd.print(sensornames[temp_sensor_id]);
  lcd.setCursor(0,1);
  if (temperature[temp_sensor_id] != TEMP_INVALID && temperature[temp_sensor_id] > warnabove_threshold[temp_sensor_id])
  {
    if (mute_counter_ > 0)
    {
      lcd.print(F("BELL Muted "));
      lcd.print(mute_counter_);
    } else {
      lcd.print(F("!OVERTEMP!!!"));
    }
  } else
  {
    lcd.print(F("Alarm "));
    if (warnabove_threshold[temp_sensor_id] == TEMPWARN_OFF) {
      lcd.print(F("OFF"));
    } else {
      lcd.print(F("@"));
      lcd.print(warnabove_threshold[temp_sensor_id]);
    }
  }
  lcd.printBig((char*)"'C", 15,0);
  lcd.printBig(tmp, 0,2);
}

byte type_s;
byte addr[8];

byte oneWireSearchAndStartConversion() {
  if ( !ds.search(addr)) {
    // Serial.println("No more addresses.");
    // Serial.println();
    ds.reset_search();
    temp_sensor_id = -1;
    return 0;
  }
  temp_sensor_id++;
  temp_sensor_id %= MAX_TEMP_SENSORS;

  // Serial.print("ROM =");
  // for( i = 0; i < 8; i++) {
  //   Serial.write(' ');
  //   Serial.print(addr[i], HEX);
  // }

  if (OneWire::crc8(addr, 7) != addr[7]) {
    temperature[temp_sensor_id] = TEMP_INVALID;
    // Serial.println("CRC is not valid!");
    return 0;
  }
  //Serial.println();
 
  // the first ROM byte indicates which chip
  switch (addr[0]) {
    case 0x10:
      // Serial.println("  Chip = DS18S20");  // or old DS1820
      type_s = 1;
      break;
    case 0x28:
      // Serial.println("  Chip = DS18B20");
      type_s = 0;
      break;
    case 0x22:
      // Serial.println("  Chip = DS1822");
      type_s = 0;
      break;
    default:
      // Serial.println("Device is not a DS18x20 family device.");
      return 0;
  } 

  ds.reset();
  ds.select(addr);
  ds.write(0x44, 1);        // start conversion, with parasite power on at the end
  return 1;
}

// get data, 800ms after conversion started
void getData() {
  byte i;
  byte data[12];

  // we might do a ds.depower() here, but the reset will take care of it.  
  ds.reset();
  ds.select(addr);    
  ds.write(0xBE);         // Read Scratchpad

  // Serial.print("  Data = ");
  // Serial.print(present, HEX);
  // Serial.print(" ");
  for ( i = 0; i < 9; i++) {           // we need 9 bytes
    data[i] = ds.read();
    // Serial.print(data[i], HEX);
    // Serial.print(" ");
  }
  // Serial.print(" CRC=");
  // Serial.print(OneWire::crc8(data, 8), HEX);
  // Serial.println();

  // Convert the data to actual temperature
  // because the result is a 16 bit signed integer, it should
  // be stored to an "int16_t" type, which is always 16 bits
  // even when compiled on a 32 bit processor.
  int16_t raw = (data[1] << 8) | data[0];
  if (type_s) {
    raw = raw << 3; // 9 bit resolution default
    if (data[7] == 0x10) {
      // "count remain" gives full 12 bit resolution
      raw = (raw & 0xFFF0) + 12 - data[6];
    }
  } else {
    byte cfg = (data[4] & 0x60);
    // at lower res, the low bits are undefined, so let's zero them
    if (cfg == 0x00) raw = raw & ~7;  // 9 bit resolution, 93.75 ms
    else if (cfg == 0x20) raw = raw & ~3; // 10 bit res, 187.5 ms
    else if (cfg == 0x40) raw = raw & ~1; // 11 bit res, 375 ms
    //// default is 12 bit resolution, 750 ms conversion time
  }
  if (temp_sensor_id < MAX_TEMP_SENSORS)
  {
    temperature[temp_sensor_id] = (float)raw / 16.0;
    // Serial.print("  Temperature = ");
    // Serial.print(temperature[temp_sensor_id]);
    // Serial.print(" Celsius, ");
  }
}

char *pSpDelimiters = (char*)" \r\n";
char *pQueryDelimiters = (char*)"& \r\n";
char *pStxDelimiter = (char*)"\002";    // STX - ASCII start of text character

/**********************************************************************************************************************
* Read the next HTTP header record which is CRLF delimited.  We replace CRLF with string terminating null.
***********************************************************************************************************************/
void getNextHttpLine(EthernetClient & client, char readBuffer[QBUF_LEN])
{
  int bufindex = 0; // reset buffer

  if (!client.connected())
    return;

  while (bufindex < QBUF_LEN-1 && client.available() > 0)
  {
    if (bufindex >= 1 && readBuffer[bufindex-1] == '\r' && readBuffer[bufindex] == '\n')
    {
      readBuffer[bufindex-1] = 0;
      break;
    }
    readBuffer[bufindex] = (char) client.read();
    bufindex++;
  }
  readBuffer[bufindex] = 0; //Null terminate string no matter what came before. mostly this will overwrite '\n'
}

// Read the first line of the HTTP request, setting Uri Index and returning the method type.
// If it is a GET method then we set the requestContent to whatever follows the '?'. For a other
// methods there is no content except it may get set later, after the headers for a POST method.
char* readRequestLine(EthernetClient & client, char readBuffer[QBUF_LEN], char requestContent[QBUF_LEN])
{
  // Get first line of request:
  // Request-Line = Method SP Request-URI SP HTTP-Version CRLF
  getNextHttpLine(client, readBuffer);
  // Split it into the 3 tokens
  char * pMethod  = strtok(readBuffer, pSpDelimiters);
  char * pUri     = strtok(NULL, pSpDelimiters);
  char * pVersion = strtok(NULL, pSpDelimiters);
  // URI may optionally comprise the URI of a queryable object a '?' and a query
  // see http://www.ietf.org/rfc/rfc1630.txt
  strtok(pUri, "?");
  char * pQuery   = strtok(NULL, "?");
  if (pQuery != NULL)
  {
    strncpy(requestContent, pQuery, QBUF_LEN-1);
    requestContent[QBUF_LEN-1] = 0; //in case strncpy ran into maximum before finding \0. Should not happen though since strtok returns \0 terminated strings
    // The '+' encodes for a space, so decode it within the string
    for (pQuery = requestContent; (pQuery = strchr(pQuery, '+')) != NULL; )
      *pQuery = ' ';    // Found a '+' so replace with a space

//    Serial.print("Get query string: ");
//    Serial.println(requestContent);
  }
  return pUri; //only valid as long as readBuffer is valid
}

void actOnRequestContent(char requestContent[QBUF_LEN])
{
  // Serial.print("actOnRequestContent\n");
  // Serial.print(requestContent);
  uint8_t tid=MAX_TEMP_SENSORS;
  if (requestContent[0] == 0)
    return;
  if (strncmp(requestContent, "bell=", 5) == 0)
  {
    if ( strncmp(requestContent + 5, "on", 2) == 0 )
    {
      bellMode_ = BELL_FORCEON;
      digitalWrite(PIN_BELL, HIGH);
    } else if ( strncmp(requestContent + 5, "off", 3) == 0 )
    {
      bellMode_ = BELL_FORCEOFF;
      digitalWrite(PIN_BELL, LOW);
    } else if ( strncmp(requestContent + 5, "mute", 4) == 0 )
    {
      muteButtonPressed();
    } else {
      bellMode_ = BELL_ALARM;
      mute_counter_ = 0;
      //bell is controlled by checkTempAndWarn()
    }
  } else if (strncmp(requestContent, "mutedur=", 8) == 0)
  {
    //"ok" since requestContent go zeroed out and is null terminated at the end for sure
    // assert QBUF_LEN > 13
    char* nexttok = strtok(requestContent+8, pQueryDelimiters);
    if (nexttok == NULL)
      return;
    bell_std_mute_duration_ = (uint8_t) atoi(nexttok);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_BELLMUTEDUR, bell_std_mute_duration_);
  } else if (strncmp(requestContent, "busid=", 6) == 0)
  {
    char* nexttok = strtok(requestContent+6, pQueryDelimiters);
    if (nexttok == NULL)
      return;
    tid = atoi(nexttok);
    if (!(tid < MAX_TEMP_SENSORS))
      return;
    nexttok = strtok(NULL, pQueryDelimiters);
    if (nexttok == NULL)
      return;
    //Important to have gotten tid BEFORE WarnAbove
    if (strncmp(nexttok, "WarnAbove=", 10) == 0)
    {
      nexttok = strtok(nexttok+10, pQueryDelimiters);
      if (nexttok == NULL)
        return;
      if (strncmp(nexttok, "off", 3) == 0)
      {
        warnabove_threshold[tid] = TEMPWARN_OFF;
      } else
      {
        warnabove_threshold[tid] = atof(nexttok);
      }
      complementFloat(&warnabove_threshold[tid],&warnabove_threshold_complement[tid]);
      eeprom_update_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
    }
  }
}


void httpReplyTempValuesJson(EthernetClient & client) {
  client.println(F("HTTP/1.1 200 OK"));
  client.println(F("Content-Type: application/json"));
  client.println(F("Cache-Control: no-cache"));
  client.println(F("Connection: close"));
  client.println();
  // print the current readings, in HTML format:
  client.print(F("{\"sensors\":["));
  for (uint8_t tid=0; tid < MAX_TEMP_SENSORS; tid++) {
    client.print(F("{\"temp\": "));
    if (temperature[tid] == TEMP_INVALID) {
      client.print(F("\"INVALID\""));
    } else {
      client.print(temperature[tid]);
    }
    client.print(F(",\"busid\":"));
    client.print(tid);
    client.print(F(", \"warnabove\":"));
    if (warnabove_threshold[tid] == TEMPWARN_OFF) {
      client.print(F("\"OFF\""));
    } else {
      client.print(warnabove_threshold[tid]);
    }
    client.print(F(",\"unit\":\"degC\",\"desc\":\""));
    client.print(sensornames[tid]);
    client.print(F("\"}"));
    if (tid < MAX_TEMP_SENSORS -1)
      client.print(F(", "));
  }
  client.print(F("],\"config\":{\"mutedur\":"));
  client.print(bell_std_mute_duration_);
  client.print(F(",\"bell\":"));
  if (bellMode_ == BELL_FORCEON)
    client.print(F("\"ON\""));
  else if (bellMode_ == BELL_FORCEOFF)
    client.print(F("\"OFF\""));
  else if (mute_counter_ > 0)
    client.print(F("\"muted\""));
  else
    client.print(F("\"connected to alarm\""));
  client.println(F("}}"));
}

void listenForEthernetClients()
{
  // listen for incoming clients
  EthernetClient client = server.available();
  if (client) {
    // Serial.println("Got a client");
    // an http request ends with \r\n\r\n (aka one blank line)
    boolean currentLineIsBlank = false;
    char reqBuf[QBUF_LEN];
    char inpBuf[QBUF_LEN];
    memset(reqBuf,0,QBUF_LEN);
    memset(inpBuf,0,QBUF_LEN);
    readRequestLine(client, inpBuf, reqBuf);
    // Serial.print("reqBuf:");
    // Serial.println(reqBuf);
    actOnRequestContent(reqBuf);
    while (client.connected()) {
      if (client.available()) {
        char c = client.read();
        // Serial.print(c);
        // if you've gotten to the end of the line (received a newline
        // character) and the line is blank, the http request has ended,
        // so you can send a reply
        if (c == '\n' && currentLineIsBlank) {
          // send a standard http response header
          httpReplyTempValuesJson(client);
          break;
        }
        if (c == '\n') {
          // you're starting a new line
          currentLineIsBlank = true;
        } else if (c != '\r') {
          // you've gotten a character on the current line
          currentLineIsBlank = false;
        }
      }
    }
    // give the web browser time to receive the data
    delay(1);
    // close the connection:
    client.stop();
  }
}

