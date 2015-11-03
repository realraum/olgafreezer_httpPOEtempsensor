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
|  2  | HD47780 Pin 14 |
|  3  | HD47780 Pin 13 |
|  4  | HD47780 Pin 12 |
|  5  | HD47780 Pin 11 |
|  6  | HD47780 Pin  6 |
|  7  | HD47780 Pin  4 |
*/

#define PIN_BELL 8
#define QBUF_LEN 128

LiquidCrystal lcd(7, 6, 5, 4, 3, 2);

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
#define EEPROM_CURRENT_VERSION 1
#define EEPROM_ADDR_VERS 0
#define EEPROM_ADDR_WARN 1
float temperature[MAX_TEMP_SENSORS] = {-9999,-9999};
float warnabove_threshold[MAX_TEMP_SENSORS] = {9999,9999};
char const *sensornames[2] = {"OLGA fridge","OLGA room"};
uint8_t temp_sensor_id = 0;
long lastReadingTime = 0;
byte readingMode = 0;
#define BELL_ALARM 0
#define BELL_FORCEOFF -1
#define BELL_FORCEON 1
int8_t bellMode_ = 0;




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


void setup() {
  // start the Ethernet connection and the server:
  Ethernet.begin(mac, ip);
  server.begin();

  // initalize the  data ready and chip select pins: 
  pinMode(PIN_BELL, OUTPUT);
  digitalWrite(PIN_BELL, LOW);

  Serial.begin(9600);

  if (eeprom_read_byte(EEPROM_ADDR_VERS) == EEPROM_CURRENT_VERSION) {
    eeprom_read_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
 //   warnabove_threshold = eeprom_read_dword(4+sizeof(float));
 //   warnabove_threshold[1] = eeprom_read_dword(4+2*sizeof(float));
  } else {
    eeprom_write_block((void*)&warnabove_threshold, (void*)EEPROM_ADDR_WARN, sizeof(float)*MAX_TEMP_SENSORS);
    //eeprom_write_float(4+sizeof(float), warnabove_threshold[0]);
    //eeprom_write_float(4+2*sizeof(float), warnabove_threshold[1]);
    eeprom_write_byte(EEPROM_ADDR_VERS, EEPROM_CURRENT_VERSION);
  }

  lcd.begin(20, 4);
  lcd.clear();
  lcd.print("OLGA Fridge         ");
  lcd.print("(c) 2015            ");
  lcd.print("         Temp Sensor");
  lcd.print(" Bernhard Tittelbach");

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
  if (bellMode_ != BELL_ALARM)
    return;
  for (uint8_t tid=0; tid < MAX_TEMP_SENSORS; tid++) {
    if (temperature[tid] > warnabove_threshold[tid])
      warn=true;
  }
  if (warn)
  {
    digitalWrite(PIN_BELL, HIGH); 
  } else
  {
    digitalWrite(PIN_BELL, LOW);
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
  lcd.print(":");
  lcd.print(sensornames[temp_sensor_id]);
  lcd.setCursor(0,1);
  lcd.print("Alarm ");
  if (warnabove_threshold[temp_sensor_id] == 9999) {
    lcd.print("OFF");
  } else {
    lcd.print("@");
    lcd.print(warnabove_threshold[temp_sensor_id]);
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
    Serial.println("No more addresses.");
    Serial.println();
    ds.reset_search();
    temp_sensor_id = -1;
    return 0;
  }
  temp_sensor_id++;
  temp_sensor_id %= MAX_TEMP_SENSORS;

  Serial.print("ROM =");
  for( i = 0; i < 8; i++) {
    Serial.write(' ');
    Serial.print(addr[i], HEX);
  }

  if (OneWire::crc8(addr, 7) != addr[7]) {
    temperature[temp_sensor_id] = -9999;
    Serial.println("CRC is not valid!");
    return 0;
  }
  Serial.println();
 
  // the first ROM byte indicates which chip
  switch (addr[0]) {
    case 0x10:
      Serial.println("  Chip = DS18S20");  // or old DS1820
      type_s = 1;
      break;
    case 0x28:
      Serial.println("  Chip = DS18B20");
      type_s = 0;
      break;
    case 0x22:
      Serial.println("  Chip = DS1822");
      type_s = 0;
      break;
    default:
      Serial.println("Device is not a DS18x20 family device.");
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

  Serial.print("  Data = ");
  Serial.print(present, HEX);
  Serial.print(" ");
  for ( i = 0; i < 9; i++) {           // we need 9 bytes
    data[i] = ds.read();
    Serial.print(data[i], HEX);
    Serial.print(" ");
  }
  Serial.print(" CRC=");
  Serial.print(OneWire::crc8(data, 8), HEX);
  Serial.println();

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
    Serial.print("  Temperature = ");
    Serial.print(temperature[temp_sensor_id]);
    Serial.print(" Celsius, ");
  }
}

char *pSpDelimiters = " \r\n";
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
  Serial.print("actOnRequestContent\n");
  Serial.print(requestContent);
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
    } else {
      bellMode_ = BELL_ALARM;
      //bell is controlled by checkTempAndWarn()
    }
  } else if (strncmp(requestContent, "busid=", 6) == 0)
  {
    char* nexttok = strtok(requestContent+6,"& \n\r");
    tid = atoi(nexttok);
    if (!(tid >= 0 && tid < MAX_TEMP_SENSORS))
      return;
    nexttok = strtok(NULL, "& \n\r");
    if (strncmp(nexttok, "warnabove=", 10) == 0)
    {
      nexttok = strtok(nexttok+10, "& \n\r");
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
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: application/json");
  client.println("Connection: close");
  client.println();
  // print the current readings, in HTML format:
  client.print("[");
  for (uint8_t tid=0; tid < MAX_TEMP_SENSORS; tid++) {
    client.print("{\"temp\": ");
    if (temperature[tid] == -9999) {
      client.print("\"INVALID\"");
    } else {
      client.print(temperature[tid]);
    }
    client.print(", \"busid\":");
    client.print(tid);
    client.print(", \"warnabove\":");
    if (warnabove_threshold[tid] == 9999) {
      client.print("\"OFF\"");
    } else {
      client.print(warnabove_threshold[tid]);
    }
    client.print(", \"scale\":\"degC\", \"desc\":\"");
    client.print(sensornames[tid]);
    client.print("\"}");
    if (tid < MAX_TEMP_SENSORS -1)
      client.print(", ");
  }
  client.print("]");
}

void listenForEthernetClients() {
  // listen for incoming clients
  EthernetClient client = server.available();
  if (client) {
    Serial.println("Got a client");
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
        Serial.print(c);
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


