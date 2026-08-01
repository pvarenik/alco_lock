// alco_sensor.ino
//
// Streams raw MQ-3 analog readings over serial, one plain integer per line,
// at 9600 baud - the exact protocol alco_lock.ps1 / alco_lock.py expect.
//
// Hardware: Arduino Uno R3 (or compatible clone, e.g. ATmega328 + CH340) +
// a standard 4-pin MQ-3 breakout module (VCC / GND / DO / AO).
// See README.md "Hardware assembly" section for wiring.

const int MQ3_PIN = A0;                    // MQ-3 AO (analog out) pin
const unsigned long SAMPLE_INTERVAL_MS = 500; // matches the host script's 0.5s poll rate

void setup() {
  Serial.begin(9600);
  // No warmup delay here on purpose - the host script does its own 10s
  // (tunable) calibration window every time it starts, reading whatever
  // the sensor reports from the moment serial opens.
}

void loop() {
  int value = analogRead(MQ3_PIN);  // 0-1023
  Serial.println(value);
  delay(SAMPLE_INTERVAL_MS);
}
