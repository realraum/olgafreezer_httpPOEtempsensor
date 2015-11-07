#include <avr/eeprom.h>
#include <SPI.h>         // needed for Arduino versions later than 0018
#include <Ethernet.h>
// the sensor communicates using SPI, so include the library:
#include <OneWire.h>
#define lcd_20X4 // Define this if you have a 20 X 4 display.
#include <LiquidCrystal.h>
#include <phi_big_font.h>

/*
^ PIN ^ Function       ^
|  13 | Ethernet / SPI |
|  12 | Ethernet / SPI |
|  11 | Ethernet / SPI |
|  10 | Ethernet / SPI |
|  9  | Onewire Temp Sensors DQ |
|  8  | NPN Transistor controlling Alarm Bell |
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
#define QBUF_LEN 128
#define PIN_MUTEBUTTON 2

//LiquidCrystal lcd(7, 6, 5, 4, 3, 2);
LiquidCrystal lcd(A0, A1, A2, A3, A4, A5);

// assign a MAC address for the ethernet controller.
// fill in your address here:
byte mac[] = {0x62,0xac,0x2e,0x6d,0x81,0x12};
// assign an IP address for the controller:
IPAddress ip(192,168,33,11);
IPAddress gateway(192,168,33,1);	
IPAddress subnet(255, 255, 255, 0);


// Initialize the Ethernet server library
// with the IP address and port you want to use 
// (port 80 is default for HTTP):
EthernetServer server(80);


OneWire  ds(9);  // on pin 10 (a 4.7K resistor is necessary)

#define MAX_TEMP_SENSORS 2
#define EEPROM_CURRENT_VERSION 2
#define EEPROM_ADDR_VERS 0
#define EEPROM_ADDR_BELLMUTEDUR 1
#define EEPROM_ADDR_WARN 2
volatile uint8_t mute_counter_ = 0;
uint8_t bell_std_mute_duration_ = 30;
float temperature[MAX_TEMP_SENSORS] = {-9999, -9999};
float warnabove_threshold[MAX_TEMP_SENSORS] = {9999, 9999};
char const *sensornames[2] = {"OLGA fridge","OLGA room"};
uint8_t temp_sensor_id = -1;
long lastReadingTime = 0;
byte readingMode = 0;
#define BELL_ALARM 0
#define BELL_FORCEOFF -1
#define BELL_FORCEON 1
volatile int8_t bellMode_ = 0;


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

void muteButtonPressed()
{
  bellMode_ = BELL_ALARM;
  if (mute_counter_ == 0) {
    mute_counter_ = bell_std_mute_duration_;
    digitalWrite(PIN_BELL, LOW);
  }
  lcd_clear();
  lcd.print(F("Mute Button Pressed"));
}

void setup() {
  // start the Ethernet connection and the server:
  Ethernet.begin(mac, ip);
  server.begin();

  // initalize the  data ready and chip select pins: 
  pinMode(PIN_BELL, OUTPUT);
  digitalWrite(PIN_BELL, LOW);
  pinMode(PIN_MUTEBUTTON, INPUT);
  digitalWrite(PIN_MUTEBUTTON, HIGH); //pullup

  //attachInterrupt(digitalPinToInterrupt(PIN_MUTEBUTTON), muteButtonPressed, FALLING);
  attachInterrupt(0, muteButtonPressed, FALLING);  //PIN2 should be Interrupt 0

  Serial.begin(9600);

  if (eeprom_read_byte(EEPROM_ADDR_VERS) == EEPROM_CURRENT_VERSION) {
    bell_std_mute_duration_ = (uint8_t) eeprom_read_byte((uint8_t *) EEPROM_ADDR_BELLMUTEDUR);
    eeprom_read_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
  } else {
    eeprom_write_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_BELLMUTEDUR, bell_std_mute_duration_);
    eeprom_write_byte((uint8_t *) EEPROM_ADDR_VERS, EEPROM_CURRENT_VERSION);
  }

  oneWireSearchAndStartConversion();

  lcd.begin(20, 4);
  lcd.clear();
  lcd.print(F("OLGA Fridge         "));
  lcd.print(F("(c) 2015            "));
  lcd.print(F("         Temp Sensor"));
  lcd.print(F(" Bernhard Tittelbach"));

  // give the sensor and Ethernet shield time to set up:
  delay(3000);

  init_big_font(&lcd);
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

  // listen for incoming Ethernet connections:
  listenForEthernetClients();
}

void checkTempAndWarn() {
  bool warn=false;

  if (bellMode_ == BELL_FORCEON)
    warn=true;
  else if (bellMode_ == BELL_FORCEOFF)
    warn=false;
  else for (uint8_t tid=0; tid < MAX_TEMP_SENSORS; tid++) {
    if (temperature[tid] != -9999 && temperature[tid] > warnabove_threshold[tid])
      warn=true;
  }

  if (warn)
  {
    if (mute_counter_ > 0)
      mute_counter_--;
    else
      digitalWrite(PIN_BELL, HIGH);
  } else
  {
    digitalWrite(PIN_BELL, LOW);
    mute_counter_ = 0;
  }
}

void displayTempOnLCD() {
  char tmp[6];
  if (! (temp_sensor_id >= 0 && temp_sensor_id < MAX_TEMP_SENSORS))
    return;

  if (temperature[temp_sensor_id] < 0)
    ftoa(tmp,temperature[temp_sensor_id],1); //leave space for minus
  else
    ftoa(tmp,temperature[temp_sensor_id],2);
  tmp[5] = 0;
  lcd_clear();
  lcd.print(temp_sensor_id);
  lcd.print(F(":"));
  lcd.print(sensornames[temp_sensor_id]);
  lcd.setCursor(0,1);
  if (temperature[temp_sensor_id] != -9999 && temperature[temp_sensor_id] > warnabove_threshold[temp_sensor_id])
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
    if (warnabove_threshold[temp_sensor_id] == 9999) {
      lcd.print(F("OFF"));
    } else {
      lcd.print(F("@"));
      lcd.print(warnabove_threshold[temp_sensor_id]);
    }
  }
  render_big_msg("$C", 13,0);
  render_big_msg(tmp, 0,2);
  //render_big_msg("$C", 3,2);
}

byte type_s;
byte addr[8];

byte oneWireSearchAndStartConversion() {
  byte i;
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
    temperature[temp_sensor_id] = -9999;
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
  byte present = 0;
  byte data[12];

  // we might do a ds.depower() here, but the reset will take care of it.  
  present = ds.reset();
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
  if (temp_sensor_id >= 0 && temp_sensor_id < MAX_TEMP_SENSORS)
  {
    temperature[temp_sensor_id] = (float)raw / 16.0;
    // Serial.print("  Temperature = ");
    // Serial.print(temperature[temp_sensor_id]);
    // Serial.print(" Celsius, ");
  }
}

char *pSpDelimiters = " \r\n";
char *pQueryDelimiters = "& \r\n";
char *pStxDelimiter = "\002";    // STX - ASCII start of text character

/**********************************************************************************************************************
* Read the next HTTP header record which is CRLF delimited.  We replace CRLF with string terminating null.
***********************************************************************************************************************/
void getNextHttpLine(EthernetClient & client, char readBuffer[QBUF_LEN])
{
  char c;
  int bufindex = 0; // reset buffer

  // reading next header of HTTP request
  if (client.connected() && client.available())
  {
    // read a line terminated by CRLF
    readBuffer[0] = client.read();
    readBuffer[1] = client.read();
    bufindex = 2;
    for (int i = 2; readBuffer[i - 2] != '\r' && readBuffer[i - 1] != '\n'; ++i)
    {
      // read full line and save it in buffer, up to the buffer size
      c = client.read();
      if (bufindex < QBUF_LEN)
        readBuffer[bufindex++] = c;
    }
    readBuffer[bufindex - 2] = 0;  // Null string terminator overwrites '\r'
  }
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
    strcpy(requestContent, pQuery);
    // The '+' encodes for a space, so decode it within the string
    for (pQuery = requestContent; (pQuery = strchr(pQuery, '+')) != NULL; )
      *pQuery = ' ';    // Found a '+' so replace with a space

//    Serial.print("Get query string: ");
//    Serial.println(requestContent);
  }
  return pUri;
}

void actOnRequestContent(char requestContent[QBUF_LEN])
{
  // Serial.print("actOnRequestContent\n");
  // Serial.print(requestContent);
  uint8_t tid=MAX_TEMP_SENSORS;
  int16_t wathint = 9999;
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
  } else if (strncmp(requestContent, "mutedur=", 13) == 0)
  {
    char* nexttok = strtok(requestContent+13, pQueryDelimiters);
    bell_std_mute_duration_ = (uint8_t) atoi(nexttok);
  } else if (strncmp(requestContent, "busid=", 6) == 0)
  {
    char* nexttok = strtok(requestContent+6, pQueryDelimiters);
    tid = atoi(nexttok);
    if (!(tid >= 0 && tid < MAX_TEMP_SENSORS))
      return;
    nexttok = strtok(NULL, pQueryDelimiters);
    if (strncmp(nexttok, "warnabove=", 10) == 0)
    {
      nexttok = strtok(nexttok+10, pQueryDelimiters);
      if (strncmp(nexttok, "off", 3) == 0)
      {
        warnabove_threshold[tid] = 9999;
      } else
      {
        wathint = atoi(nexttok);
        warnabove_threshold[tid] = (float) wathint;
      }
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
    if (temperature[tid] == -9999) {
      client.print(F("\"INVALID\""));
    } else {
      client.print(temperature[tid]);
    }
    client.print(F(",\"busid\":"));
    client.print(tid);
    client.print(F(", \"warnabove\":"));
    if (warnabove_threshold[tid] == 9999) {
      client.print(F("\"OFF\""));
    } else {
      client.print(warnabove_threshold[tid]);
    }
    client.print(F(",\"scale\":\"degC\",\"desc\":\""));
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

void listenForEthernetClients() {
  // listen for incoming clients
  EthernetClient client = server.available();
  if (client) {
    // Serial.println("Got a client");
    // an http request ends with a blank line
    boolean currentLineIsBlank = true;
    uint8_t linenum = 0;
    char reqBuf[QBUF_LEN];
    char inpBuf[QBUF_LEN];
    memset(reqBuf,0,QBUF_LEN);
    memset(inpBuf,0,QBUF_LEN);
    readRequestLine(client, inpBuf, reqBuf);
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


