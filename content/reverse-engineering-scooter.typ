#import "@preview/bytefield:0.0.8": (
  bit, bitheader, bits, byte, bytefield as orig-bytefield, bytes, flag, note,
)
#import "/templates/base.typ": video
#import "/templates/post.typ": post
#import "/components/ui.typ": sidenote, sidenote-mark
#import "/components/layout.typ" as L
#import "@preview/chronos:0.3.0"
#import "@preview/blockcell:0.1.0" as B
#import "@preview/oxifmt:1.0.0": strfmt
#import "@preview/autograph:0.1.0" as autograph
#import "@preview/fletcher:0.5.8" as fletcher
#import "@preview/frame-it:2.0.0" as frame-it

#let args = (
  title: "Reverse engineering my e-scooter and rewriting the firmware in rust",
  date: "2026-08-09",
  slug: "reverse-engineering-scooter",
  tags: ("programming", "rust", "reverse-engineering"),
  summary: "I reverse engineered the hardware and firmware of my Egret GT E-Scooter. I describe how I got in, analysed communication between components, and reverse engineered firmware. I speak about writing custom firmware for the display unit.",
)

#show: post.with(..args)

#show math.ast: sym.times

#let typst_block(body) = {
  context {
    if target() == "html" {
      html.div(
        class: "p-4 w-full flex flex-row place-content-center invert-svg-dark fix-svg",
      )[
        #html.frame(block(width: 450pt, body))
      ]
    } else {
      body
    }
  }
}

#let bytefield(..args) = typst_block(orig-bytefield(..args))

#let can_inner(id, length, body) = stack(
  dir: ltr,
  B.cell(baseline: 0%, stroke: none, fill: gray)[id: #strfmt("{:#x}", id)],
  B.cell(baseline: 0%, stroke: none, fill: aqua)[len: #strfmt("{}", length)],
  B.cell(baseline: 0%, stroke: none, fill: silver)[body: #(
    body
      .map(it => if type(it) == int {
        strfmt("{:#x}", it)
      } else {
        [#it]
      })
      .join(", ")
  )],
)
#let can(id, length, body) = box(
  fill: gray,
  stroke: 1pt + black,
  clip: true,
  radius: 1pt,
)[#can_inner(id, length, body)]

#let can-inline(id, length, body) = html.span(
  class: "inline-block align-sub invert-svg-dark",
)[
  #html.frame(block(can(id, length, body)))
]


#let (alert,) = frame-it.frames(
  alert: ("Alert",),
)

#show: frame-it.frame-style(frame-it.styles.thmbox)

#image("../assets/images/scooter/Demo shot.png")

== Introduction

Last year, I bought myself an #link("https://my-egret.com/e-models/egret-gt/")[Egret GT]. It's an e-scooter that touts a
range of 100km and has very large tyres which makes driving it quite comfortable. To make sure you know that it's a
high-end e-scooter, it comes with a 320x480 LCD display used as a HUD, on which the speed, driving mode, battery level
and range are displayed.

Now because I have to #strike[break] tinker with everything I own, I eventually decided to start figuring out how this
thing worked. I can't remember exactly why, but it was possibly due to the fact that holding the 'down' button on the
keypad while powering the scooter would cause it to enter a firmware update mode. If you clicked a button to exit this
menu, you would enter the normal 'driving' mode, and would be able to use the scooter without entering the PIN. While I
always secure the scooter with a reasonably good lock, this still irked me a bit.

The first thing I started on was the mobile app, which allows you to unlock the scooter remotely, change a few settings,
and view the battery level. I won't bore you with the process, but what I found from skimming through the bluetooth
handlers of the app was the following:

1. The scooter can perform firmware updates over bluetooth, and seemingly there exists a few different places a firmware
  update can go (display, controller, button panel).

2. Some metrics which are not shown in the app or on the scooter are transmitted over bluetooth, such as the time spent
  in each driving mode, device temperature, motor current, battery voltage, battery charging history. Details such as
  the total driving time, odometer, and charge history are transmitted to the manufacturer and stored attached to the
  scooter's ID, this behaviour is not clearly mentioned in the app :)))))))

3. The scooter doesn't know its Vehicle Identification Number until the app connects and sets it. If you set this using
  a bluetooth debug app yourself, the Egret app can be spoofed to think the scooter is a different model. I tried to
  spoof the VIN of the 45km/h model of the scooter to see if the speed limit was implemented with such a simple check,
  but this didn't work.

Eventually I became bored at playing with the bluetooth interface and turned to the USB-C port on the display. The
manufacturer states that this is just for charging phones, and after some testing with different devices I did conclude
that if the data pins were connected, the display unit wouldn't act as either a USB host or device. But I knew better,
and ordered a USB-C breakout board. When this arrived, I plugged it in and probed each pin with an oscilloscope. To my
surprise, two of the USB-C pins were being used as a CAN bus (which smells horribly noncompliant).

== CAN Bus sniffing

#figure(
  caption: [An oscilloscope attached to the CAN bus of the scooter, decoding messages.],
  image("../assets/images/scooter/image_20260908_155128.png"),
)

To sniff this can traffic, I threw together an abomination (pictured in @can-dumper) using an ESP32-C6, a SN65HVD230, and a
MCP2515#sidenote-mark(<two-can>).

#sidenote(
  <two-can>,
)[ The reason for two CAN transceivers is that the SN65HVD230 could be used by the ESP-CAN peripheral
  to listen to messages, but for some reason wasn't able to transmit properly (would cause a bus error). I later added
  the MCP2515, which is able to transmit. I kept both because the SN65HVD230 exposed an async interface in the rust
  library I was using for the firmware, which makes receiving messages as part of a state machine easy. ]

#figure(
  caption: [The device],
  image("../assets/images/scooter/CAN dumper.png"),
) <can-dumper>

I put together a quick program which initialised the CAN peripherals and logged every can message. Then I plugged my CAN
logger into the scooter and recorded the messages during startup:

```
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[74, bd, 0, 0, 16, c, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[74, bd, 0, 0, 16, c, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[73, bd, 0, 0, 3, c, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[73, bd, 0, 0, 3, c, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[72, bd, 0, 0, ef, b, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[72, bd, 0, 0, ef, b, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[74, bd, 0, 0, e9, b, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[74, bd, 0, 0, e9, b, 0, 0]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:774,false,[55, 0, 0, 0, 2, 0, 0, 0]
CAN_FRAME:513,false,[0, 0, 0, 0, 0]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, 21, 0]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:768,false,[0, 5a, 64, 5a, 64, 0, 0, 0]
CAN_FRAME:494,false,[60, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[4c, 44, 2e, 43, 52, 2e, 53, 38]
CAN_FRAME:495,false,[30, 37, 2e, 43, 2e, 32, 2e, 31]
CAN_FRAME:495,false,[45, 47, 2e, 32, 2e, 32, 2e, 31]
CAN_FRAME:495,false,[31, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:768,false,[0, 5a, 64, 5a, 64, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:495,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:1856,true,[4b, 0]
CAN_FRAME:1024,false,[0, 40, 87, 4, 0, 0, 0, 0]
CAN_FRAME:1025,false,[74, bd, 0, 0, e4, b, 0, 0]
CAN_FRAME:1857,true,[4b, 0, 0, 0, 69, 99, 52, 42]
CAN_FRAME:1028,false,[20, 4e, 0, 0, 1, 0, b9, b]
CAN_FRAME:1860,true,[1]
CAN_FRAME:1861,true,[1, 15, 57, 20, 50, 59, 54, 34]
CAN_FRAME:774,false,[54, 0, 0, 0, 2, 0, 0, 0]
CAN_FRAME:513,false,[0, 0, 0, 0, 2]
CAN_FRAME:515,false,[0, 0, 0, 0, 0, 0, ff, 1f]
CAN_FRAME:528,false,[0, 0, 0, 0, 0, 0, 0, 0]
CAN_FRAME:768,false,[0, 5a, 64, 5a, 64, 0, 0, 0]
```

The CAN bus proved to be quite noisy, so to figure out what was going on I built a small tool using
#link("https://github.com/emilk/egui")[egui] to show a plot of can messages against time. By plotting each can message
as a dot with the y-axis as the can message ID, it becomes very easy to identify which messages are commands, responses,
and periodic data.

#image("../assets/images/scooter/SCR-20260808-jfzf.png")

Unfortunately at this point I still didn't have a good idea which purpose each message had. But by sniffing the bus
while running the scooter, I was able to quickly figure out which messages were used in communicating the throttle,
driving mode, and motor speed:

- 0x300: Sent by the display to the controller. Contains the current driving mode (walk, eco, drive, sport), whether the
  headlight is on, and in walk mode contains a counter in the last nibble. Sending a message where the fourth byte is
  `a5` instead of the usual `5a` causes the controller to reset. <can-300>

  #bytefield(
    bitheader("offsets", 17, [Headlight]),
    bytes(2)[Speed mode],
    flag(fill: silver)[],
    flag[],
    bits(6, fill: silver)[],
    byte[Operation/ Reboot],
    byte[constant: 0x64],
    byte(fill: silver)[],
    byte[Speed mode, unused],
    bits(4, fill: silver)[],
    bits(4)[Counter],
  )

  An example is #can-inline(0x300, 8, (0x0, 0x5a, 0x64, 0x5a, 0x64, 0, 0, 0)) which decodes to:

  #table(
    columns: 2,
    [Driving mode], [Walk (`0x00_90`)],
    [Headlight], [Operating (`0x64`)],
    [Walk counter], [0],
  )


- 0x306: Sent by the display to the controller. Contains the throttle position, the blinker lights, and the speed limit
  of the scooter. The speed limit has no effect on the standard GT controller, but on the GTS it sets the speed limit to
  25, 35, or 45km/h. For some reason the throttle level is transmitted as a 9 bit unsigned integer with the MSB being
  the first bit of the second byte.

  #bytefield(
    bitheader(
      "offsets",
      13,
      [Right~blinker],
      14,
      [Left~blinker],
      15,
      [Throttle~msb],
    ),
    byte[Throttle position],
    bits(5, fill: silver)[],
    flag[],
    flag[],
    flag[],
    byte(fill: silver)[],
    byte[Speed limit],
    bytes(4)[constant: 0x02_00_00_00],
  )

  An example is #can-inline(0x306, 8, (0xff, 0b011, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00)) which decodes to:

  #table(
    columns: 2,
    [Throttle], [511],
    [Left blinker], [true],
    [Right blinker], [false],
    [Speed limit], [25km/h (`0`)],
  )

- 0x201: Contains motor speed, and some status flags.
  #bytefield(
    bitheader(
      "offsets",
      5,
      [Brake~light~on],
      6,
      [Headlight~on],
      7,
      [Walk~mode],
    ),
    bytes(2)[Motor speed],
    bytes(2, fill: silver)[],
    bits(5, fill: silver)[],
    flag[],
    flag[],
    flag[],
    bytes(3, fill: silver)[],
  )

  An example is #can-inline(0x201, 5, (7, 4, 0, 0, 0b100)) which decodes to:

  #table(
    columns: 2,
    [Motor speed], [1031],
    [Walk mode], [false],
    [Headlight on], [false],
    [Brake light on], [true],
  )

In the end, I documented all of the CAN messages:
#link("https://github.com/simmsb/scooter-display/blob/master/docs/System%20communication/CAN/CAN%20bus%20messages.md")[here].

At this point I was now able to do some amusing stuff, like controlling the scooter's motor remotely, but this isn't
very practical or interesting. This project kind of stalled at this point as I had no access to the firmware and
therefore there was little more I could do. A few months later I noticed that it was possible to buy replacement motor
controller and display units online. I couldn't resist the opportunity, so I ordered replacements of both.

== Teardowns and firmware extraction

The first component I tore down was the controller. This was particularly difficult as the rear plate was secured very
tightly with crosshead screws, of which the heads of two stripped immediately, requiring me to dremel a slot. The device
was also filled with some type of potting compound, but very thankfully the compound was actually quite soft and could
easily be scraped away.

#L.flex-row(
  class: "picture-like",
)[
  #image("../assets/images/scooter/Pasted image 20260808120220.png")

  #image("../assets/images/scooter/Pasted image 20260808114617.png")

  #image("../assets/images/scooter/Pasted image 20260808114911.png")
]

After removing the potting compound, I was presented with quite the gift: None of the active components had had their
markings etched away, and there was a row of four pads on the back side of the board. The MCU was marked with
APM32E103xCxE (a STM32F103 clone), therefore these pins are very likely the SWD port. By using
#link("https://openocd.org/")[OpenOCD]#sidenote-mark(<image-dumping>) I was able to dump the flash and the
RAM#sidenote-mark(<ram-dump>) contents shortly after boot.

#sidenote(
  <image-dumping>,
)[ To dump images, I used a STLINK connected to these 4 pins (VCC, GND, CLK, DIO) and ran:
  `openocd -f interface/stlink.cfg -f target/stm32f1x.cfg -c "init; dump_image flash.bin 0x00000000 0x80000; shutdown"`.
  For ram the command is the same, just with `0x20000000` instead of `0x0` as the base address. ]

#sidenote(
  <ram-dump>,
)[ Capturing the RAM contents proved to be very useful as the firmware appears to store a lot of
  pointers in RAM which don't change over the lifetime. Having these present gave Ghidra an easy time following
  references. ]

With the firmware dumped I could start analysing it with Ghidra#sidenote-mark(<ghidra-quick>). I very quickly found the
main CAN message handler, which allowed me to further document the purpose of each CAN message.

#sidenote(<ghidra-quick>)[
  A quick rundown of how I did this:

  1. Import the flash image, set the language to `ARM Cortex little (default)`. Click options and set the base address
    to `0x8000000`.

  2. Open the code browser, skip analysis for now.

  3. Use `File -> Add to program` to add the RAM image, click options and set the base address to `0x20000000`.

  4. Use the #link("https://github.com/antoniovazquezblanco/GhidraSVD")[SVD loader] plugin to load in the SVD file for
    the MCU. This is critical as it allows you to see clearly where peripherals (e.g. GPIO or the CAN bus) are being
    used.

  5. You should now run the analysis. Don't enable aggressive instruction finder unless, I found it falsely identifies
    too many functions in data areas.

  6. Seek to `0x8000004`, at this location is a pointer to the reset function (AKA main). Jump to the address and
    dissassemble/create a function if there isn't one already.

  7. Start exploring from reset. There's usually a lot of boilerplate HAL code here such as the clock setup and the code
    that loads static variables into RAM. There will likely also be a lot of noreturn functions here that ghidra won't
    identify, which will cause decompiled code to appear in multiple locations. My only advice here is to click through
    until you see code that looks like application code - typically application code starts by initialising
    peripherals, so if you see GPIO/UART/CAN mentioned, you are probably in the right place.

  8. Be aware that the code starting at 0x8000000 might be the bootloader. If ghidra says the function modifies the
    stack pointer, this might be the 'bootload' function which is jumping to the main firmware by setting the stack
    pointer and jumping to the reset handler. If you look at the location where this function is taking the stack
    pointer and reset function from, you'll likely find the interrupt vector of the main application.
]

#figure(
  image("../assets/images/scooter/Pasted image 20260808131805.png"),
  caption: [Decompilation showing the handlers for messages 0x300 and 0x306],
)

I also discovered that a total of three applications live on the controller MCU: A bootloader located at 0x8000000, an
'updater' at 0x8003000, and the main application at 0x8006200. The bootloader sets up the CAN bus and listens for a
short time to see if any 'update' packets arrive, to see if a firmware update over the CAN bus is in progress. For some
reason both the bootloader and 'updater' firmware contain a mechanism to update the application firmware over CAN bus,
both use a different update scheme.

#L.flex-row(
  class: "picture-like",
  figure(
    image("../assets/images/scooter/20260815-171706.png"),
    caption: [
      Ghidra open on the 'bootload' function of the controller. This can be identified by it writing the address of the reset
      function (`image[1]`) to the start of RAM (`0x20000000`), setting the stack pointer (`image[0]`), and
      then jumping to the reset function. The reset function will handle setting up the NVIC.
    ],
  ),
  figure(
    image("../assets/images/scooter/20260815-172427.png"),
    caption: [
      The application image. The first two words are the initial stack pointer address and the reset function,
      followed by the addresses of the interrupt handlers. Note how it's quite repetitive,
      this makes it easy to identify.
    ],
  ),
)

Another funny note is that at 0x8006000 the length of the application firmware is stored, but not as a four or eight
byte unsigned integer as you'd inspect, but instead as an ascii string of the base-10 representation of the number. Even
wilder is that the entire region after the length up to 0x80061ff is padded with ascii space characters, and terminated
with `\r\n`.

#figure(
  image("../assets/images/scooter/Pasted image 20260808143333.png"),
  caption: [
    The contents of memory just before the main application starts.
  ],
)

After exploring a small amount further, I decided to turn my attention to the display unit. The majority of the code in
the controller appears to be the FOC motor control code, and I didn't feel particularly comfortable modifying the safety
critical part of the device, especially after discovering that the controller contains some fairly reasonable safety
precautions, such as shutting down if the display stops sending valid throttle positions after a short period.

== Display unit

Cracking open the display unit required much more effort than the controller. It's constructed from a reasonably tough
and thick (2mm) injection molded body, so I used a dremel to cut into the back side. I had assumed the front screen
cover was heat welded on, and so I also started using a dremel around the edge, but once I had cut a slot and had some
leverage, I was able to simply pry the cover off as it was only glued.

#figure(
  image("../assets/images/scooter/Pasted image 20260808114150.png"),
  caption: [Topside of the display unit, I'm using a #link("https://glasgow-embedded.org/")[Glasgow] as the debugger],
)

The board for the display was quite interesting as it had several unused through hole pin header rows and multiple
microcontrollers. I identified the chips to be the following:

1. Main MCU: AT32F415
2. Bluetooth MCU: CH573
3. NFC reader IC: FM17520
4. CAN Transceiver
5. SPI flash chip: W25Q128FV

One debug header was the SWD port for the main MCU, so I repeated the process of dumping the firmware there. Another
provided access to the SPI flash, so I also dumped this, but it only contained only the bitmap images used by the GUI
shown on the display.

The display firmware is structure similarly to the control unit, with a bootloader which is capable of receiving
firmware updates over the CAN bus.

1. The display unit firmware is structured as a bootloader and a main application at 0x8008000.

2. The GUI is drawn using SEGGER EMWin.

3. The bluetooth MCU communicates over GPIOA 2 and 3 using UART at 57500k, using a simple framing scheme. When a
  bluetooth attribute is read, the CH573 sends a request message with a number indicating a handler in the main MCU
  firmware. The main MCU sends back a response message with the same command number and the response body.

4. The NFC module also communicates over UART at 115200k, with a slightly different protocol. I didn't look into this
  much further.

5. The button panel on the handlebars of the scooter communicates with the display unit also over UART, at 9600k. The
  only message it sends is a simple bitfield of the buttons that are pressed. Interestingly, it handles the blinking of
  the indicators itself; It blinks the lights and also has two bits in its message which indicates the blinker state.
  It appears to also be able to receive firmware updates.

6. The CAN bus is connected over pins GPIOA 11 and 12.

7. The display is a ST7796 controller, connected over a parallel interface; All 16 pins on GPIOB are used as a parallel
  data bus, which allows the firmware to update the state of all pins in just one instruction.

8. The ADC reads from three channels: An ambient light sensor on ch12, the throttle voltage on ch13, and the battery
  voltage on ch15. The firmware only reads the battery voltage to trigger an error message when it is too low, for all
  other usages of the battery level the firmware reads a variable updated by a CAN message sent by the battery. (Yeah,
  the battery is on the bus.)

9. The firmware of the display unit is, like the controller, updated over CAN. And again like the controller, the actual
  update code lives in the bootloader; The application firmware simply reboots itself if it sees an update initiation
  message, the bootloader then sees the next message and starts the update process. Yes, this also means that it's
  possible to modify the firmware of any scooter without authentication :)))))

Initially the display firmware was a pain to reverse engineer, the version of Ghidra that I was using had a bug which
caused it to not properly tag function pointers located in areas identified as data, due to the pointers having their
lower bits set (indicating that the function uses THUMB instructions). Since the firmware is structured around tables of
callbacks - for CAN, bluetooth, and GUI screens - I was unable to locate the callers of a lot of functions. By luck I at
some point encountered the function which scans through the CAN handlers table and was able to ascertain the structure
of the CAN handler table, and since every entry in the table specifies the ID to match on, and optionally an interval
and a tx and/or rx callback, I was now able to quickly locate the corresponding code for each CAN message that I observed.

#L.flex-row(
  class: "picture-like",
)[
  #figure(
    caption: [Ghidra with the function of the display unit which handles sending the #link(<can-300>)[0x300] CAN message],
  )[
    #image("../assets/images/scooter/Pasted image 20260808150404.png")
  ]

  #figure(
    caption: [A table of CAN handlers defined at 0x200001a0],
  )[
    #image("../assets/images/scooter/image_20260831_154201.png")
  ]

  #figure(
    caption: [The entry for CAN message 0x306, it has a transmit callback and a specified interval],
  )[
    #image("../assets/images/scooter/image_20260831_161504.png")
  ]
]

Through extensive cross referencing of both the display and controller firmware, I was able to build up a mostly
complete understanding of the CAN messages, the only messages I didn't complete were some related to the apple find my
feature, which I'm not particularly interested in because I don't have an iphone and instead built my own tracker device
using openhaystack, which has the extra benefit of not triggering any 'tracker following' messages as it rotates
identity every 30 minutes :)

Next up was figuring out the GPIO and peripheral configurations, which I'd need to begin writing my own firmware.
Thankfully this is actually pretty easy as the firmware is using the
#link("https://github.com/ArteryTek/AT32F415_Firmware_Library/tree/773f88703eddd7b49d72d36ae560b887f67ee9fb/libraries/drivers/src")[manufacturer
  provided peripheral library] and also didn't use any form of LTO when compiling, so the decompilation output for the
compiled HAL provided functions very closely matches the source.

#L.flex-row(class: "picture-link")[
  #figure(
    caption: [Decompilation result for the GPIO_Init function, which is pretty much identical to the #link("https://github.com/ArteryTek/AT32F415_Firmware_Library/blob/773f88703eddd7b49d72d36ae560b887f67ee9fb/libraries/drivers/src/at32f415_gpio.c#L99")[source]],
  )[
    #image("../assets/images/scooter/image_20260831_164720.png")
  ]

  #figure(
    caption: [Decompilation of the function initialising UART5, we can see which pins are statically configured as tx and
      rx by the contents of the `GPIO_Pins` field, and the configuration of the UART peripheral. The baud rate is passed as a parameter for some reason.],
  )[
    #image("../assets/images/scooter/image_20260831_165756.png")
  ]
]

Using this technique of matching up decompiled library functions with source code, and using the name and type
information obtained by doing so to discover peripheral configs, allowed me to fully map out all the GPIO pins and the
configurations of all the peripherals..

Another thing that aided in my reverse engineering was that the firmware had left in a debug menu (it seems to be
unreachable from the actual firmware, but the code is still there). The debug menu displays some button and headlight
statuses, so I was instantly able to fill out a 'button state' enum.

#figure(caption: [Decompilation of the debug menu])[
  #image("../assets/images/scooter/image_20260831_172827.png")
]

At this point I had pretty much figured out enough information to begin writing my own firmware; The CAN messages
required to operate the motor controller were fully mapped out, as were the GPIO pins and peripheral configurations, and
I'd also reverse engineered the UART protocol of the bluetooth MCU. I'd even put together a block diagram of all the
individual components of the scooter that communicate:

#image("../assets/images/scooter/Architecture diagram.png")

Running my own firmware on the cracked open display unit would be trivial, as I can just use a debug probe to flash it.
But to get my firmware onto a usable display unit I'd need to reverse engineer the firmware update process.

== Firmware updates

Thankfully (for me) the firmware update process ended up being extremely simple, with no cryptography involved and the
main lifecycle of a firmware update living entirely within one function in the bootloader.

A firmware update starts in a CAN message handler for ID 0x384. If the message is #can-inline(0x384, 1, (0x43,)) then
the firmware resets, and if the message is #can-inline(0x384, 7, (0xAA, 0x04, 0x04, 0x52, 0x45, 0x50, 0x07)) then the
scooter erases the flash regions used to store the VIN and scooter configuration.

#L.flex-row(
  class: "picture-like",
)[
  #figure(
    caption: [Ghidra with the function of the display unit which handles CAN messages with ID 0x384],
  )[
    #image("../assets/images/scooter/Pasted image 20260808204303.png")
  ]

  #figure(
    caption: [The core of the firmware update loop, after a chunk's CRC is validated, the bootloader directly writes into flash.],
  )[
    #image("../assets/images/scooter/20260831-145347.png")
  ]
]


The device performing the firmware update then continues to send
#can-inline(0x384, 1, (0x43,)) messages until the bootloader starts up, sees an
update initiation message, and replies with #can-inline(0x700, 1, (0x06,)). The
updater device then sends 64 byte chunks spread over 9 CAN 0x384 frames, where each frame
has the following structure:

- *Frame 0*
  #bytefield(
    bitheader("offsets"),
    byte[0x01],
    byte[sequence],
    byte[$"0xff" - "sequence"$],
    byte[data[0]],
    bytes(4)[data[1..5]],
  )

- *Frame 1..9*
  #bytefield(
    bitheader("offsets"),
    bytes(4)[data[$5 + N * 8 .. 9 + 5 * 8$]],
    bytes(4)[data[$9 + N * 8 .. 13 + 5 * 8$]],
  )

- *Frame 9*
  #bytefield(
    bitheader("offsets"),
    bytes(3)[data[61..64]],
    bytes(2)[crc],
    bytes(3, fill: gray)[],
  )

The CRC is `CRC-16-CCITT` over the `data`. The data of each chunk is padded with zeros to make 64 bytes before
calculating the CRC. `sequence` is an unsigned byte, starting at 0 and incrementing for each chunk transmitted, after
0xFF it wraps to 0.

The first chunk is not the first 64 bytes of the firmware, but instead the update file name (for example:
`AT_R2_JHZY_GT1_GE_FM_HW02_4.0.2`) as a null terminated string, followed by the firmware length as a base-10 encoded,
null terminated string. The bootloader replies to the first chunk four times with #can-inline(0x700, 1, (0x06,)), and
all subsequent chunks with one #can-inline(0x700, 1, (0x06,)).

After the first chunk is sent, the updater device then sends the firmware image a chunk at a time. The scooter replies
with one #can-inline(0x700, 1, (0x06,)) message after the last CAN message of a frame is sent and the CRC is validated.
After the firmware has been transmitted, the updater sends #can-inline(0x384, 1, (0x04,)), which triggers a reboot of
the display unit. The update mechanism directly writes over the application image in flash, so a failed update will
brick the display. However, the bootloader always checks for the presence of #can-inline(0x384, 1, (0x43,)) packets when
powering up, allowing a firmware update to begin even if the application code isn't functional.

In summary, the update process follows this sequence diagram (you can tell I'm having fun with typst here :)):

#figure(caption: [Sequence diagram of update process])[
  #html.div(class: "w-full flex flex-row place-content-center invert-svg-dark")[
    #html.frame(block[
      #chronos.diagram({
        import chronos: *
        _par("U", display-name: "Updater")
        _par("S", display-name: "Scooter")

        _seq("U", "S", comment: [#can(0x384, 1, (0x43,))])
        _note("right", [Scooter reboots], pos: "S")
        _loop("Until response", {
          _seq("U", "S", comment: [#can(0x384, 1, (0x43,))])
        })

        _seq("S", "U", comment-align: "right", comment: [#can(0x700, 1, (
          0x6,
        ))])

        _seq("U", "S", comment: [
          #B.region[
            #set align(left)
            #can(0x384, 8, (1, [seq], [0xff - seq], "...data[0..5]")) \
            #B.target[
              #can(0x384, 8, ("data[5..13]",)) \
              #B.note[Repeats 7 times]
            ] \
            #can(0x384, 8, ("...data[61..63]", "crc[0]", "crc[1]"))
          ]
        ])

        _seq("S", "U", comment-align: "right", comment: [
          #B.target[
            #can(0x700, 8, (0x06,)) \
            #B.note[Repeats 4 times]
          ]
        ])

        _loop("For all 64 byte chunks of update", {
          _seq("U", "S", comment: [
            #B.region[
              #set align(left)
              #can(0x384, 8, (1, [seq], [0xff - seq], "...data[0..5]")) \
              #B.target[
                #can(0x384, 8, ("data[5..13]",)) \
                #B.note[Repeats 7 times]
              ] \
              #can(0x384, 8, ("...data[61..63]", "crc[0]", "crc[1]"))
            ]
          ])
          _seq("S", "U", comment-align: "right", comment: [#can(0x700, 1, (
            0x06,
          ))])
        })

        _seq("U", "S", comment: [#can(0x384, 1, (0x04,))])
        _note("right", [Scooter reboots], pos: "S")
      })
    ])
  ]
]

To actually do the firmware update, I extended the CAN dumping firmware that I wrote earlier into
#link("https://github.com/simmsb/egret-can-flasher")[this], which simply flashes a firmware image embedded inside.

#image("../assets/images/scooter/Pasted image 20260809140250.png")

Great, I can now update the firmware on the device. To confirm this worked I tried it out with the firmware image I'd
dumped from the cracked open device to begin with, and it worked first time.

== Rewrite it in rust

Now I could begin writing some firmware in Rust. There was a small problem though, the display unit MCU is the AT32F415,
which is a STM clone, but it seems to not be a clone of a specific STM chip, but instead a mish-mash of STM32
peripherals, most appear to match up with the STM32F1, but the RTC seems to be from a STM32F3. This is annoying because
it means I can't just jumpstart to writing firmware using #link("https://embassy.dev/")[Embassy], instead I need to
first build my own HAL#sidenote-mark(<hal>).

#sidenote(<hal>)[Hardware access library.]

#link("https://github.com/kossnikita")[Kossnikita] had already started on this using a fork of stm32-rs, so I was
thankfully able to take this and #link("https://github.com/simmsb/at32f4xx-hal")[start adding support] for the
peripherals I needed. I must admit I mostly cheated here; for most of the peripherals I started by taking the
implementation from Embassy, and then I, with both the datasheet of the stm32f1 and the at32f415 open, updated the
peripheral code to match the register names used by the AT32. There's very likely a better way here, such as adding the
chip as an entry in #link("https://github.com/embassy-rs/stm32-data")[stm32-metapac], which is a subproject of Embassy
which processes SVD files to create PAC#sidenote-mark(<pac>) crates, but I initially assumed the AT32 was more
different than it is.

#sidenote(<pac>)[Peripheral Access Crate.]

I started by bringing up each peripheral, the clocks and timers first, as a timer allows me to add an
#link("https://github.com/embassy-rs/embassy/tree/main/embassy-time-driver")[embassy-time-driver] implementation. Then
the ADC, external GPIO interrupts, UART, CAN, and RTC peripherals. With the HAL drivers implemented I could then start
writing code to drive the display, read the ADC inputs, and talk over the CAN and UART buses.

Bringing up the display was entirely straightforward, using the #link("https://github.com/almindor/mipidsi")[mipidsi]
crate for the display driver, all I had to do myself was add a
#link(
  "https://docs.rs/mipidsi/latest/mipidsi/interface/struct.ParallelInterface.html",
)[ParallelInterface]
implementation in the HAL that allows writing a u16 to all the GPIO pins in one operation:

```rust
/// A bus of gpio pins
///
/// SHIFT: which range of pins are we operating on: 0 => 0..16, 8 => 8..16
/// MASK: bitmask used to select which pins are members of this bus. The mask is unshifted.
pub struct Bus<const P: char, const SHIFT: u8, const MASK: u16, MODE = DefaultMode> {
    _mode: PhantomData<MODE>,
}

impl<const P: char, const SHIFT: u8, const MASK: u16, MODE> Bus<P, SHIFT, MASK, MODE> {
    fn _set_state(&mut self, state: u16) {
        unsafe {
            (*Gpio::<P>::ptr()).odt().modify(|r, w| {
                // we only need to read the previous state if the mask doesn't
                // cover everything.
                let prev = if const { MASK & 0xFFFF != 0xFFFF } {
                    r.bits() & !(MASK as u32)
                } else {
                    0
                };
                let new = ((state << SHIFT) & MASK) as u32;
                w.bits(prev | new)
            });
        }
    }

    fn _get_state(&self) -> u16 {
        unsafe {
            let unshifted = (*Gpio::<P>::ptr()).odt().read().bits() & !(MASK as u32);
            (unshifted >> SHIFT) as u16
        }
    }
}

impl<const P: char, const SHIFT: u8, const MASK: u16> mipidsi::interface::OutputBus
    for Bus<P, SHIFT, MASK, Output>
{
    type Word = u16;

    const KIND: mipidsi::interface::InterfaceKind = InterfaceKind::Parallel16Bit;

    type Error = Infallible;

    #[inline(always)]
    fn set_value(&mut self, value: Self::Word) -> Result<(), Self::Error> {
        self.set_state(value);
        Ok(())
    }
}
```

We can then declare the pins used in the display as rust types:

```rust
pub type Bus = at32f4xx_hal::gpio::Bus<'B', 0, 0xFFFF, Output>;
pub type CsPin = Pin<'C', 13, Output>;
pub type DcPin = Pin<'C', 14, Output>;
pub type RdPin = Pin<'C', 0, Output>;
pub type WrPin = Pin<'C', 15, Output>;
pub type RstPin = Pin<'C', 1, Output>;
pub type Backlight = PwmChannel<at32f4xx_hal::pac::TMR2, 0>;
pub type InnerDisplay = mipidsi::Display<
    mipidsi::interface::ParallelInterface<Bus>,
    mipidsi::models::ST7796,
    RstPin,
>;

pub fn init(
    mut rd: RdPin,
    mut cs: CsPin,
    dc: DcPin,
    wr: WrPin,
    rst: RstPin,
    bus: Bus,
    delay: &mut SysDelay,
    backlight: Backlight,
) -> Display {
    cs.set_low();
    rd.set_high();

    let interface = mipidsi::interface::ParallelInterface::new(bus, dc, wr);
    let mut display = mipidsi::Builder::new(mipidsi::models::ST7796, interface)
        .reset_pin(rst)
        .invert_colors(mipidsi::options::ColorInversion::Inverted)
        .orientation(mipidsi::options::Orientation {
            rotation: mipidsi::options::Rotation::Deg0,
            mirrored: true,
        })
        .color_order(mipidsi::options::ColorOrder::Bgr)
        .init(delay)
        .unwrap();

    Display {
        _cs_pin: cs,
        _rd_pin: rd,
        inner: display,
        backlight,
    }
}
```

And now we have a #link("https://docs.rs/mipidsi/latest/mipidsi/struct.Display.html")[Display] which we can draw to. By
opening up the compiled firmware in Ghidra we can also confirm that the data transmission loop turns into a simple loop
which writes a sequence of bytes to a single MMIO register:

```c
void __rustcall mipidsi::interface::parallel::send_command<>(ParallelInterface<> *self,u8 command,&[u8] args)

{
  byte *pbVar1;
  u8 *puVar2;

  _DAT_40010c0c = command & 0xff;
  _DAT_422202b8 = 1;
  _DAT_42220238 = 1;
  pbVar1 = args.data_ptr;
  for (puVar2 = args.len; puVar2 != 0x0; puVar2 = puVar2 + -1) {
    _DAT_40010c0c = *pbVar1;
    pbVar1 = pbVar1 + 1;
    _DAT_422202bc = 1;
    _DAT_4222023c = 1;
  }
  return;
}
```

With the display working, I next worked on implementing encoding and decoding of the CAN and bluetooth protocols. For
this I used #link("https://github.com/sharksforarms/deku")[deku] as it allows you to declare byte and bit level parsers
for structs using a quite concise macro#sidenote-mark(<can-proto-impls>):

#sidenote(
  <can-proto-impls>,
)[The full protocol implementation can be found #link("https://github.com/simmsb/scooter-display/blob/master/src/can_proto.rs")[here]]

#figure[
  ```rust
  /// 513
  #[derive(deku::DekuRead, deku::DekuSize, defmt::Format, Clone, PartialEq, Eq)]
  #[cfg_attr(test, derive(deku::DekuWrite, Debug))]
  #[deku(bit_order = "lsb", endian = "little")]
  pub struct ControllerSpeed {
      /// In km/h * 100
      #[deku(pad_bytes_after = "2")]
      pub motor_speed: u16,

      #[deku(bits = 1)]
      pub walk_mode: bool,

      #[deku(bits = 1)]
      pub headlight_on: bool,

      #[deku(bits = 1, pad_bits_after = "5")]
      pub brake_light_on: bool,
  }

  #[test]
  fn test_display_throttle() {
      let mut buf = [0u8; 8];
      deser_roundtrip(&mut buf, &DisplayThrottle::new(511, false, false, 0));
      assert_eq!(buf, [0xff, 0b1, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]);

      deser_roundtrip(&mut buf, &DisplayThrottle::new(511, true, false, 0));
      assert_eq!(buf, [0xff, 0b011, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]);

      deser_roundtrip(&mut buf, &DisplayThrottle::new(511, true, true, 2));
      assert_eq!(buf, [0xff, 0b111, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00]);

      deser_roundtrip(&mut buf, &DisplayThrottle::new(1, false, true, 2));
      assert_eq!(buf, [0x01, 0b100, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00]);

      deser_roundtrip(&mut buf, &DisplayThrottle::new(256, false, true, 2));
      assert_eq!(buf, [0x00, 0b101, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00]);
  }
  ```] <encoders-and-decoders>

The neat thing about doing this in rust is that I could then take these definitions and use them in a completely
different program to decode the CAN logs into something human readable:

#figure(caption: [The same CAN logs shown earlier, now decoded])[
  ```
  L1 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L2 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48500, current_ma: 3094 })
  L3 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L4 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L5 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48500, current_ma: 3094 })
  L6 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L7 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L8 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L9 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L10 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L11 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48499, current_ma: 3075 })
  L12 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L13 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L14 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L15 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L16 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L17 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48499, current_ma: 3075 })
  L18 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L19 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L20 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L21 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L22 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L23 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48498, current_ma: 3055 })
  L24 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L25 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L26 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L27 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L28 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L29 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48498, current_ma: 3055 })
  L30 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L31 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L32 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L33 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L34 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L35 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48500, current_ma: 3049 })
  L36 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L37 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L38 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L39 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L40 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L41 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48500, current_ma: 3049 })
  L42 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L43 id=774 ext=false from=display DisplayThrottle(DisplayThrottle { throttle: 85, left_blinker: false, right_blinker: false, speed_limit: 0, magic: DekuConst })
  L44 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: false, brake_light_on: false })
  L45 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 33 })
  L46 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L47 id=768 ext=false from=display DisplaySpeedMode(DisplaySpeedMode { mode: 0, mode_high: 90, headlight: 100, magic: Normal, speed_mode_byte: 0, walk_counter: 0 })
  L48 id=494 ext=false from=display unknown [60, 00, 00, 00, 00, 00, 00, 00]
  L49 id=495 ext=false from=unknown unknown [4c, 44, 2e, 43, 52, 2e, 53, 38]
  L50 id=495 ext=false from=unknown unknown [30, 37, 2e, 43, 2e, 32, 2e, 31]
  L51 id=495 ext=false from=unknown unknown [45, 47, 2e, 32, 2e, 32, 2e, 31]
  L52 id=495 ext=false from=unknown unknown [31, 00, 00, 00, 00, 00, 00, 00]
  L53 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L54 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L55 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L56 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L57 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L58 id=768 ext=false from=display DisplaySpeedMode(DisplaySpeedMode { mode: 0, mode_high: 90, headlight: 100, magic: Normal, speed_mode_byte: 0, walk_counter: 0 })
  L59 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L60 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L61 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L62 id=495 ext=false from=unknown unknown [00, 00, 00, 00, 00, 00, 00, 00]
  L63 id=1856 ext=true from=display unknown [4b, 00]
  L64 id=1024 ext=false from=battery BatteryCommandState(BatteryCommandState { command: 16384, state: 1159, estimated_range: 0 })
  L65 id=1025 ext=false from=battery BatteryVoltageCurrent(BatteryVoltageCurrent { voltage_mv: 48500, current_ma: 3044 })
  L66 id=1857 ext=true from=unknown unknown [4b, 00, 00, 00, 69, 99, 52, 42]
  L67 id=1028 ext=false from=battery BatteryCapacityTemp(BatteryCapacityTemp { capacity_mah: 20000, battery_charged: true, battery_charging: false, battery_temp: 270 })
  L68 id=1860 ext=true from=display unknown [01]
  L69 id=1861 ext=true from=battery unknown [01, 15, 57, 20, 50, 59, 54, 34]
  L70 id=774 ext=false from=display DisplayThrottle(DisplayThrottle { throttle: 84, left_blinker: false, right_blinker: false, speed_limit: 0, magic: DekuConst })
  L71 id=513 ext=false from=controller ControllerSpeed(ControllerSpeed { motor_speed: 0, walk_mode: false, headlight_on: true, brake_light_on: false })
  L72 id=515 ext=false from=controller ControllerSpeedMode(ControllerSpeedMode { unknown: 8191 })
  L73 id=528 ext=false from=controller ControllerSpeedLimit(ControllerSpeedLimit { speed_limit: false })
  L74 id=768 ext=false from=display DisplaySpeedMode(DisplaySpeedMode { mode: 0, mode_high: 90, headlight: 100, magic: Normal, speed_mode_byte: 0, walk_counter: 0 })
  ```
]

== Actor-modelling

Now that the protocols are implemented, it becomes quite easy to write state machines
using Embassy to handle incoming messages (both external messages from the CAN bus or bluetooth MCU, or internally
defined messages for communicating button presses, events triggered by the UI, and ADC readings) and update relevant
state. Overall, using the actor model for firmware is really quite a breeze, when all tasks communicate over well
defined interfaces instead of reading and writing to shared global memory, reasoning about the system becomes
simplified, and in my case, writing an emulator tool to test the GUI proved easy.

In the end, I ended up with this set of actors and relationships:

#figure(
  caption: [Diagram of tasks (Grey) and resources (Coloured). Arrows indicate direction of data flow.],
)[
  #typst_block(autograph.diagram(
    engine: "neato",
    node-shape: fletcher.shapes.pill,
    node-inset: 2pt,
    cell-size: 4em,
    edge-corner-radius: 1pt,
    {
      let node(..args) = autograph.node(fill: gray, ..args)
      (
        node(<adc-task>, [ADC]),
        node(<system-state-task>, [System state]),
        node(<operation-state-task>, [Operation state]),
        node(<gui-task>, [GUI]),
        node(<bluetooth-tx-task>, [Bluetooth TX]),
        node(<bluetooth-rx-task>, [Bluetooth RX]),
        node(<can-tx-task>, [CAN TX]),
        node(<can-rx-task>, [CAN RX]),
        node(<button-rx-task>, [Button RX]),
        node(<button-event-task>, [Button event]),
        node(<config-store-task>, [Config store]),
      )
    },
    {
      let node(..args) = autograph.node(fill: olive, ..args)
      (
        node(<throttle-pos-device>, [Throttle position]),
        node(<ambient-light-device>, [Ambient light level]),
        node(<can-bus-device>, [CAN Bus]),
        node(<bluetooth-uart-device>, [Bluetooth UART]),
        node(<button-uart-device>, [Button UART]),
        node(<display-device>, [Display]),
        node(<power-button-device>, [Power button]),
        node(<flash-storage-device>, [Flash storage]),
      )
    },
    {
      import autograph: edge
      (
        edge(<adc-task>, <operation-state-task>),
        edge(<adc-task>, <system-state-task>),
        edge(<system-state-task>, <gui-task>),
        edge(<system-state-task>, <bluetooth-tx-task>),
        edge(<system-state-task>, <operation-state-task>),
        edge(<operation-state-task>, <gui-task>),
        edge(<operation-state-task>, <can-tx-task>),
        edge(<operation-state-task>, <config-store-task>),
        edge(<gui-task>, <operation-state-task>),
        edge(<bluetooth-rx-task>, <operation-state-task>),
        edge(<bluetooth-rx-task>, <bluetooth-tx-task>),
        edge(<can-rx-task>, <operation-state-task>),
        edge(<can-rx-task>, <system-state-task>),
        edge(<button-rx-task>, <button-event-task>),
        edge(<button-event-task>, <gui-task>),
      )
    },
    {
      import autograph: edge
      (
        edge(<throttle-pos-device>, <adc-task>),
        edge(<ambient-light-device>, <adc-task>),
        edge(<can-tx-task>, <can-bus-device>),
        edge(<can-bus-device>, <can-rx-task>),
        edge(<bluetooth-uart-device>, <bluetooth-rx-task>),
        edge(<bluetooth-tx-task>, <bluetooth-uart-device>),
        edge(<button-uart-device>, <button-rx-task>),
        edge(<gui-task>, <display-device>),
        edge(<power-button-device>, <button-event-task>),
        edge(<config-store-task>, <flash-storage-device>),
      )
    },
  ))
]

=== #link(
  "https://github.com/simmsb/scooter-display/blob/master/src/adc.rs",
)[The ADC Task]

This task reads the ADC periodically, and publishes readings onto a channel that other tasks can subscribe to.

```rust
pub static ADC_READINGS: embassy_sync::pubsub::PubSubChannel<embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex, AdcReading, 4, 4, 1> = embassy_sync::pubsub::PubSubChannel::new();

pub static THROTTLE_READINGS: embassy_sync::watch::Watch<embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex, Throttle, 4> = embassy_sync::watch::Watch::new();

pub static AMBIENT_READINGS: embassy_sync::watch::Watch<embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex, AmbientLight, 4> = embassy_sync::watch::Watch::new();

async fn adc_task_(
    mut adc: Adc<ADC1>,
    // ambient light
    ch12: Pin<'C', 2, Analog>,

    // throttle
    ch13: Pin<'C', 3, Analog>,
) {
    let mut do_sample_ticker = embassy_time::Ticker::every(Duration::from_millis(50));

    let state_reading_ch = ADC_READINGS.publisher().unwrap();
    let throttle_reading_ch = THROTTLE_READINGS.sender();
    let ambient_reading_ch = AMBIENT_READINGS.sender();

    // the ambient light level is averaged so that it doesn't flicker
    let mut ambient_light_averager = MovingAverage::<u16, u32, 16>::new();

    loop {
        // sample the throttle and ambient light every 50ms
        do_sample_ticker.next().await;

        defmt::trace!("ADC measuring ambient");
        let val = adc.convert(&ch12, SampleTime::Cycles_480).await;
        let avg = ambient_light_averager.average(val);
        let ambient_light = AmbientLight::from_raw(avg);
        state_reading_ch
            .publish(AdcReading::AmbientLight(ambient_light))
            .await;
        ambient_reading_ch.send(ambient_light);

        defmt::trace!("ADC measuring throttle");
        let val = adc.convert(&ch13, SampleTime::Cycles_480).await;
        let thr = Throttle::from_raw(val);
        state_reading_ch.publish(AdcReading::Throttle(thr)).await;
        throttle_reading_ch.send(thr);
    }
}
```

To handle converting raw ADC readings to usable numbers, I use the following newtype pattern:

```rust
#[derive(Eq, PartialEq, Default, defmt::Format, Clone, Copy, Debug)]
pub struct Throttle(pub u16);

impl Throttle {
    pub const INITIAL: Self = Self(0);

    // value we report to the controller when throttle is fully depressed
    const OUT_MAX: u32 = 360;

    fn from_raw(raw: u16) -> Self {
        // value the adc reads when throttle is fully depressed
        const MAX_RAW: u32 = 2820;

        // value the adc reads when the throttle is unpressed
        const MIN_RAW: u32 = 730;

        Self(
            (raw as u32)
                .clamp(MIN_RAW, MAX_RAW)
                .saturating_sub(MIN_RAW)
                .saturating_mul(Self::OUT_MAX)
                .saturating_div(MAX_RAW - MIN_RAW)
                .saturating_truncate(),
        )
    }

    pub(crate) fn for_bluetooth(&self) -> u8 {
        const MAX_BT: u32 = 146;

        (self.0 as u32)
            .saturating_mul(MAX_BT)
            .saturating_div(Self::OUT_MAX)
            .saturating_truncate()
    }

    pub fn adjust_for_speed_limit(
        &self,
        // current speed limit setpoint (e.g. 271)
        speed_limit: u16,
        // speed limit set on the controller
        // (250/350/450). for a speed_limit of 271
        // this should be 350.
        controller_speed_limit: u16,
    ) -> u16 {
        // This is just a linear scale for now. I need to find how the speed
        // actually responds over throttle values.
        (self.0 as u32)
            .saturating_mul(speed_limit as u32)
            .saturating_div(controller_speed_limit as u32)
            .saturating_truncate()
    }
}
```

=== #link(
  "https://github.com/simmsb/scooter-display/blob/master/src/system_state.rs",
)[The 'System state' task]

The system state (I'm bad at naming) task is used to maintain the read-only and calculated state of the system, that is:
The battery level, current speed, temperature, and the odometer and predicted range.


```rust
#[derive(PartialEq, Eq, defmt::Format, Clone)]
pub struct SystemState {
    /// motor speed, in deca meters per hour (speed / 100 = km/h)
    pub motor_speed: u16,
    pub headlight_on: bool,
    pub brake_light_on: bool,

    pub controller_temp: u8,
    pub system_voltage: SystemVoltage,
    pub controller_speed_limit_mode: bool,

    pub battery_current: i16,
    pub battery_debug: BatteryDebug,
    pub battery_info: BatteryInfo,

    pub throttle: Throttle,
    pub ambient_light: AmbientLight,

    pub buttons: Buttons,
    /// in km
    pub odometer: u16,

    /// in km
    pub predicted_range: u16,
}

#[embassy_executor::task]
async fn system_state_updater() {
	let can_messages = CAN_MESSAGES.receiver();
	let bt_commands = BT_COMMANDS.receiver();
	let mut adc_readings = crate::adc::ADC_READINGS.subscriber().unwrap();
	let state_updated = STATE_UPDATES.sender();
	let mut buttons_reader = BUTTON_STATE_WATCH.receiver().unwrap();

	let mut update_private_state_ticker =
		Ticker::every(Duration::from_secs(PRIVATE_STATE_UPDATE_PERIOD_SECS));

	let mut private_state = PrivateState::default();

	loop {
		let updated = match select::select5(
			can_messages.receive(),
			bt_commands.receive(),
			adc_readings.next_message_pure(),
			buttons_reader.changed(),
			update_private_state_ticker.next(),
		)
		.await
		{
			select::Either5::First(can_msg) => {
				update_state(|s| s.update_from_can_message(&can_msg));
				private_state.update_from_can_message(&can_msg);
				true
			}
			select::Either5::Second(_) => false,
			select::Either5::Third(reading) => {
				update_state(|s| s.update_from_adc_reading(reading))
			}
			select::Either5::Fourth(buttons) => {
				update_state(|s| s.buttons = buttons);
				true
			}
			select::Either5::Fifth(_) => {
				private_state.periodic_update();
				update_state(|s| private_state.update_public(s));
				true
			}
		};

		if updated {
			state_updated.send(());
		}
	}
}

impl SystemState {
	pub fn update_from_can_message(&mut self, msg: &CanMessage) {
		match msg {
			CanMessage::ControllerStatus(ControllerStatus { battery_level, .. }) => {
				self.battery_info.level_from_controller = *battery_level;
			}
			CanMessage::ControllerSpeed(ControllerSpeed {
				motor_speed,
				headlight_on,
				brake_light_on,
				..
			}) => {
				self.motor_speed = *motor_speed;
				self.headlight_on = *headlight_on;
				self.brake_light_on = *brake_light_on;
			}
			CanMessage::ControllerTempMotor(ControllerTempMotor { temp, voltage }) => {
				self.controller_temp = *temp;
				self.system_voltage.from_controller = *voltage;
			}
			CanMessage::ControllerSpeedMode(ControllerSpeedMode { .. }) => {}
			CanMessage::ControllerSpeedLimit(ControllerSpeedLimit { speed_limit }) => {
				self.controller_speed_limit_mode = *speed_limit;
			}
			CanMessage::BatteryCommandState(BatteryCommandState {
				command,
				state,
				estimated_range,
			}) => {
				self.battery_debug = BatteryDebug {
					command: *command,
					state: *state,
					estimated_range: estimated_range.truncate(),
				}
			}
			CanMessage::BatteryVoltageCurrent(BatteryVoltageCurrent {
				voltage_mv,
				current_ma,
			}) => {
				self.system_voltage.from_battery = voltage_mv.truncate();
				self.battery_current = current_ma.truncate();
			}
			CanMessage::BatteryChargeLevel(BatteryChargeLevel {
				relative_soc,
				absolute_soc_mah,
			}) => {
				self.battery_info.relative_soc = relative_soc.truncate();
				self.battery_info.absolute_soc = absolute_soc_mah.truncate();
			}
			CanMessage::BatteryStateOfHealth(BatteryStateOfHealth {
				relative_soh,
				absolute_soh_mah,
			}) => {
				self.battery_info.relative_soh = *relative_soh;
				self.battery_info.absolute_soh = absolute_soh_mah.truncate();
			}
			CanMessage::BatteryCapacityTemp(BatteryCapacityTemp {
				capacity_mah,
				battery_charged,
				battery_charging,
				battery_temp,
			}) => {
				self.battery_info.capacity = *capacity_mah;
				self.battery_info.charged = *battery_charged;
				self.battery_info.charging = *battery_charging;
				self.battery_info.temperature = *battery_temp;
			}
			_ => {}
		}
	}
}
```

=== #link(
  "https://github.com/simmsb/scooter-display/blob/master/src/operation.rs",
)[The 'Operation state' task]

The main part of my scooter firmware is what I call the 'operation state', which is the driving state and all other
state which is influenced by the driver. That is: whether the scooter is locked or unlocked, the speed mode the scooter
is in, whether the headlight is on, off, or in auto mode, and the speed limit the scooter is configured to.

The state machine receives command such as 'unlock' and 'set speed mode' from the UI, and handles sending CAN messages
to the controller depending on the current operation state and throttle position. The operation state itself is an enum
with two states: Locked, and Unlocked. The main data of the operation state is only available within the unlocked state,
which should prevent any chance of misbehaviour, such as being able to drive while the scooter is locked.

```rust
#[derive(PartialEq, Eq, defmt::Format, Clone, Copy)]
pub enum OperationCommand {
    Unlock,
    Lock,
    UnlockSpeedLimit,
    LockSpeedLimit,
    SetSpeedLimit(u16),
    SetSpeedMode(SpeedMode),
    SetHeadlightMode(HeadlightMode),
}

#[derive(PartialEq, Eq, defmt::Format, Clone)]
pub enum OperationState {
    Locked(Option<UnlockCode>),
    Active(ActiveState),
}

#[derive(PartialEq, Eq, defmt::Format, Clone)]
pub struct ActiveState {
    pub throttle: Throttle,

    /// Speed limit in km/h * 10, we'll later use this to select the 25/35/45 limit
    /// sent to the controller
    pub speed_limit: u16,

    pub speed_limit_unlocked: bool,

    pub speed_mode: SpeedMode,

    pub walk_mode_counter: Option<NibbleCounter>,

    pub headlight_mode: HeadlightMode,
    pub headlight_config: HeadlightConfig,
}

#[embassy_executor::task]
async fn operation_task() {
    defmt::info!("Operation task startup");

    let mut send_can_messages_ticker = embassy_time::Ticker::every(Duration::from_millis(100));

    let mut throttle_readings = crate::adc::THROTTLE_READINGS.receiver().unwrap();
    let mut ambient_readings = crate::adc::AMBIENT_READINGS.receiver().unwrap();

    let operation_commands = OPERATION_COMMANDS.receiver();

    let state_updates = STATE_UPDATES.sender();

    let unlock_code = UnlockCode::get_stored().await;
    defmt::info!("Loaded unlock code: {}", unlock_code);

    update_state(|s| {
        if s.is_locked() {
            *s = OperationState::Locked(Some(unlock_code));
        }
    });

    state_updates.send(());

    loop {
        match select::select4(
            send_can_messages_ticker.next(),
            throttle_readings
                .changed()
                .with_timeout(Duration::from_secs(1)),
            ambient_readings.changed(),
            operation_commands.receive(),
        )
        .await
        {
            select::Either4::First(_) => {
                send_speed_and_throttle_can_messages().await;
            }
            select::Either4::Second(Ok(throttle)) => {
                update_state(|s| s.update_if_active(|a| a.throttle = throttle));

                state_updates.send(());
            }
            select::Either4::Second(Err(_)) => {
                panic!("Operation task did not receive throttle update in time");
            }
            select::Either4::Third(ambient) => update_state(|s| {
                s.update_if_active(|a| {
                    if a.headlight_mode == HeadlightMode::Auto {
                        if !a.headlight_config.auto_on && ambient.mapped < a.headlight_config.low {
                            a.headlight_config.auto_on = true;
                            state_updates.send(());
                        } else if a.headlight_config.auto_on
                            && ambient.mapped > a.headlight_config.high
                        {
                            a.headlight_config.auto_on = false;
                            state_updates.send(());
                        }
                    }
                })
            }),
            select::Either4::Fourth(op_cmd) => {
                defmt::info!("Handling op command: {}", op_cmd);
                match op_cmd {
                    OperationCommand::Unlock => {
                        let speed_limit = SpeedLimit::get_stored().await.get_validated();
                        let speed_mode = SpeedMode::get_stored().await;
                        let headlight_mode = HeadlightMode::get_stored().await;

                        update_state(|s: &mut OperationState| {
                            *s = OperationState::Active(ActiveState {
                                throttle: Throttle(0),
                                speed_limit,
                                speed_limit_unlocked: false,
                                walk_mode_counter: None,
                                speed_mode,
                                headlight_mode,
                                headlight_config: HeadlightConfig {
                                    low: 5,
                                    high: 13,
                                    auto_on: false,
                                },
                            })
                        })
                    }
                    OperationCommand::Lock => {
                        let unlock_code = UnlockCode::get_stored().await;
                        update_state(|s| *s = OperationState::Locked(Some(unlock_code)))
                    }
                    OperationCommand::SetSpeedLimit(new_limit) => {
                        let validated = SpeedLimit::new_validated(new_limit);
                        SpeedLimit::update_stored(validated);
                        update_state(|s| {
                            s.update_if_active(|a| a.speed_limit = validated.get_validated())
                        })
                    }
                    OperationCommand::SetSpeedMode(speed_mode) => {
                        SpeedMode::update_stored(speed_mode);
                        update_state(|s| s.update_if_active(|a| a.speed_mode = speed_mode))
                    }
                    OperationCommand::SetHeadlightMode(headlight_mode) => {
                        HeadlightMode::update_stored(headlight_mode);
                        update_state(|s| {
                            s.update_if_active(|a| {
                                a.headlight_mode = headlight_mode;
                            })
                        })
                    }
                    OperationCommand::UnlockSpeedLimit => update_state(|s| {
                        s.update_if_active(|a| {
                            a.speed_limit_unlocked = true;
                        })
                    }),
                    OperationCommand::LockSpeedLimit => update_state(|s| {
                        s.update_if_active(|a| {
                            a.speed_limit_unlocked = false;
                        })
                    }),
                }

                state_updates.send(());
            }
        }
    }
}

```

=== #link(
  "https://github.com/simmsb/scooter-display/blob/master/src/ui/firmware.rs",
)[GUI Task]

The GUI task handles running the UI, all 'actions' in the UI are translated into messages that are sent to the operation
state task. The GUI task also runs from a lower priority executor, which allows the other tasks to run in parallel such
that long processing times in the GUI thread don't prevent important tasks from operating.

=== #link("https://github.com/simmsb/scooter-display/blob/master/src/bluetooth.rs")[Bluetooth], #link("https://github.com/simmsb/scooter-display/blob/master/src/can.rs")[CAN], and #link("https://github.com/simmsb/scooter-display/blob/master/src/buttons.rs")[Button] tasks

The bluetooth, CAN, and button are simple message forwarders that translate between structured messages and the wire
format. There isn't much to talk about here, they use the encoders and decoders I spoke about in @encoders-and-decoders.

=== #link(
  "https://github.com/simmsb/scooter-display/blob/master/src/noodle.rs",
)[Config store task]

To be able to remember things like the odometer, last used driving mode, unlock pin, and speed limit, we need a way to
persist these values to flash storage. To do this, I use the
#link("https://github.com/tweedegolf/sequential-storage")[sequential-storage] crate, which provides a key-value
interface on top of flash storage. It's designed so that writes are wear levelled (by spreading writes over multiple
sectors), and to be reliable.

Config entries are declared using a macro, and can be any rust type implementing the required traits:

```rust
#[derive(defmt::Format, PartialEq, Eq, Copy, Clone, derive_enum_rotate::EnumRotate, Default, serde::Serialize, serde::Deserialize)]
#[rustfmt::skip]
pub enum HeadlightMode {
    #[default]
    Auto,
    On,
    Off,
}

saved_item!(2, HEADLIGHT_MODE, HeadlightMode, 10);

pub(crate) trait Storable:
    Default + PartialEq + Clone + for<'a> sequential_storage::map::Value<'a> + 'static
{
    const ID: u8;

    fn take_if_changed_and_timedout() -> Option<Self>;
    fn mark_unchanged();
    fn update_stored(val: Self);
    async fn get_stored() -> Self;
    fn maybe_get_stored() -> Option<Self>;
}

macro_rules! saved_item {
    ($id:expr, $name:ident, $ty:ty, $timeout:literal) => {
        static $name: embassy_sync::blocking_mutex::Mutex<
            embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex,
            Option<($ty, bool, Instant)>,
        > = embassy_sync::blocking_mutex::Mutex::new(None);

        impl<'a> ::sequential_storage::map::PostcardValue<'a> for $ty {}

        paste::paste! {
            static [<WAKER_ $name>]: embassy_sync::waitqueue::AtomicWaker = embassy_sync::waitqueue::AtomicWaker::new();

            impl Storable for $ty {
                const ID: u8 = $id;

                fn take_if_changed_and_timedout() -> Option<Self> {
                    let now = Instant::now();
                    unsafe {
                        $name.lock_mut(|s| {
                            let (x, v, t) = s.as_mut()?;

                            if *v && (now > *t) {
                                *v = false;
                                return Some(x.clone());
                            }

                            None
                        })
                    }
                }

                fn mark_unchanged() {
                    unsafe {
                        $name.lock_mut(|s| {
                            if let Some((_, v, _)) = s.as_mut() {
                                *v = false;
                            };
                        })
                    }
                }

                fn update_stored(val: Self) {
                    let now = Instant::now();
                    let t = now.saturating_add(Duration::from_secs($timeout));
                    unsafe {
                        $name.lock_mut(|s| {
                            if let Some((prev, prev_changed, prev_t)) = s.as_mut() {
                                if &val != prev {
                                    *prev_changed = true;
                                    *prev = val;
                                    *prev_t = if *prev_t < now { t } else { *prev_t };
                                }
                            } else {
                                *s = Some((val, true, t));
                            }
                        })
                    }
                    [<WAKER_ $name>].wake();
                }

                async fn get_stored() -> Self {
                    core::future::poll_fn(|cx| {
                        if let Some((v, _, _)) = $name.lock(|s| s.clone()) {
                            core::task::Poll::Ready(v)
                        } else {
                            [<WAKER_ $name>].register(cx.waker());
                            core::task::Poll::Pending
                        }
                    })
                    .await
                }

                fn maybe_get_stored() -> Option<Self> {
                    if let Some((v, _, _)) = $name.lock(|s| s.clone()) {
                        Some(v)
                    } else {
                        None
                    }
                }
            }
        }
    };
}
```

Throughout the codebase, these config values can be read and updated at will:

```rust
// read the config entry, this is an async so that this code can
// wait for the entry to be loaded from flash at startup
let foo = HeadlightMode::get_stored().await;

// set value
HeadlightMode::update_stored(HeadlightMode::Auto);
```

The config store worker is the task that handles loading and persisting these config values to storage.

#figure(
  caption: [The config store worker handles writing changed entries. It implements a cooldown system so that frequent changes don't thrash],
)[```rust
pub async fn worker_(flash: at32f4xx_hal::pac::FLASH) {
    defmt::debug!(
        "FLASH INFO: start: {:x}, end: {:x}, len: {:x}",
        config_start(),
        config_end(),
        config_end() - config_start()
    );

    let mut buffer = [0u8; 32];

    let mut map_storage = MapStorage::<u8, _, _>::new(
        MyFlash(flash),
        MapConfig::new(0..8192),
        Cache::new_uncached(),
    );

    init_stored::<SpeedLimit, _, _>(&mut map_storage, &mut buffer);
    init_stored::<HeadlightMode, _, _>(&mut map_storage, &mut buffer);
    init_stored::<SpeedMode, _, _>(&mut map_storage, &mut buffer);
    init_stored::<UnlockCode, _, _>(&mut map_storage, &mut buffer);
    init_stored::<Odometer, _, _>(&mut map_storage, &mut buffer);

    loop {
        Timer::after_secs(10).await;

        write_stored_if_changed::<SpeedLimit, _, _>(&mut map_storage, &mut buffer);
        write_stored_if_changed::<HeadlightMode, _, _>(&mut map_storage, &mut buffer);
        write_stored_if_changed::<SpeedMode, _, _>(&mut map_storage, &mut buffer);
        write_stored_if_changed::<UnlockCode, _, _>(&mut map_storage, &mut buffer);
        write_stored_if_changed::<Odometer, _, _>(&mut map_storage, &mut buffer);
    }
}

fn init_stored<T: Storable, S: NorFlash, C: CacheImpl<u8>>(
    map_storage: &mut MapStorage<u8, S, C>,
    buf: &mut [u8],
) {
    match embassy_futures::block_on(map_storage.fetch_item::<T>(buf, &T::ID)) {
        Ok(Some(v)) => {
            T::update_stored(v);
            let _ = T::take_if_changed_and_timedout();
        }
        r => {
            if r.is_err() {
                defmt::warn!("Failed to fetch entry for id {}, loading default", T::ID);
            } else {
                defmt::debug!("No stored entry found for id {}, loading default", T::ID);
            }
            T::update_stored(T::default());
            T::mark_unchanged();
        }
    }
}

fn write_stored_if_changed<T: Storable, S: NorFlash, C: CacheImpl<u8>>(
    map_storage: &mut MapStorage<u8, S, C>,
    buf: &mut [u8],
) {
    if let Some(v) = T::take_if_changed_and_timedout() {
        if embassy_futures::block_on(map_storage.store_item(buf, &T::ID, &v)).is_ok() {
            defmt::debug!("Updated entry for id {}", T::ID);
        } else {
            defmt::warn!("Failed to write changed item for id {}", T::ID);
        }
    }
}
```]

== I want the GUI to be pretty too, not just the code

Now for the part of the firmware that I think is actually most novel, the HUD interface. For C projects there are lots
of libraries here, including LVGL, SEGGER EmWIN. In Rust we have lots of GUI libraries too (egui, slint, gpui) and some
of these are even targeted at embedded systems, but unfortunately all of them either require STD, an allocator, or a
framebuffer, all of which I can't support on a microcontroller with 32k of RAM.

By chance I came across #link("https://github.com/riley-williams/buoyant")[Buoyant], which is a rust library providing a
SwiftUI-like interface for constructing GUIs, while also requiring no framebuffer, memory allocations or the standard
library. It also comes with focus/keyboard navigation support, which is exactly what I need as the scooter has no
touchscreen.

I really like the API offered by buoyant, I really didn't have to fight much to put together a UI that looks quite
pretty. For example, here's the entire code for the pin entry screen:

```rust
#[derive(PartialEq, Eq, Clone, Copy, defmt::Format, Default)]
pub struct State {
    pin: [pin_digit::PinDigit; 4],
}

#[must_use]
pub fn view(state: &state::State) -> impl View<ColorFormat, state::State> + use<> {
    VStack::new((
        Text::new("Enter PIN", &font::B612_REGULAR).foreground_color(colour::on_background()),
        Lens::new(pin_entry(&state.locked_state), |s: &mut state::State| {
            &mut s.locked_state
        }),
        Button::new(
            |state: &mut state::State| {
                if state.locked_state.pin
                    == state
                        .operation_state
                        .as_locked()
                        .and_then(|x| *x)
                        .unwrap_or_default()
                        .digits
                {
                    state.locked_state.pin = Default::default();
                    let _ = state.next_operation_commands.push(OperationCommand::Unlock);
                }
            },
            |bs| {
                Text::new("Confirm", &font::B612_REGULAR)
                    .padding(Edges::All, 4)
                    .foreground_color(if bs.is_focused() {
                        colour::on_primary()
                    } else {
                        colour::on_primary_fixed()
                    })
                    .background_color(
                        if bs.is_focused() {
                            colour::primary()
                        } else {
                            colour::primary_fixed()
                        },
                        RoundedRectangle::new(4),
                    )
            },
        ),
    ))
    .with_spacing(2)
    .with_alignment(HorizontalAlignment::Center)
    .flex_infinite_width(HorizontalAlignment::Center)
    .with_infinite_max_height()
    .map_event(|event, _: &mut ()| match event {
        Event::KeyDown(key) => match *key {
            keys::UP_CLICK => Some(FocusAction::Previous.into_event(focus::GROUP_0)),
            keys::DOWN_CLICK => Some(FocusAction::Next.into_event(focus::GROUP_0)),
            keys::CONFIRM_CLICK => Some(FocusAction::Select.into_event(focus::GROUP_0)),
            _ => None,
        },
        Event::KeyUp(_) => None,
        _ => Some(event.clone()),
    })
}

fn pin_entry(state: &State) -> impl View<ColorFormat, State> + use<> {
    HStack::new((
        Lens::new(pin_piece(state.pin[0]), |s: &mut State| &mut s.pin[0]),
        Lens::new(pin_piece(state.pin[1]), |s: &mut State| &mut s.pin[1]),
        Lens::new(pin_piece(state.pin[2]), |s: &mut State| &mut s.pin[2]),
        Lens::new(pin_piece(state.pin[3]), |s: &mut State| &mut s.pin[3]),
    ))
}

fn pin_piece(pin: pin_digit::PinDigit) -> impl View<ColorFormat, pin_digit::PinDigit> {
    Rotary::new(
        |pin: &mut pin_digit::PinDigit, event: RotaryEvent| match event {
            RotaryEvent::Next => *pin = pin.prev(),
            RotaryEvent::Previous => *pin = pin.next(),
            RotaryEvent::Select | RotaryEvent::Exit => {}
        },
        move |rotary_state| {
            Text::new(pin.as_str(), &font::B612_REGULAR_LARGE_NUMBERS)
            .padding(Edges::All, 4)
            .foreground_color(
                match rotary_state {
                    RotaryState::UnFocused => colour::on_background(),
                    RotaryState::Focused => colour::on_background(),
                    RotaryState::Captive => colour::on_primary_fixed(),
                }
            )
            .background(Alignment::Center,
                        match_view!(rotary_state, {
                            RotaryState::UnFocused => EmptyView,
                            RotaryState::Focused => RoundedRectangle::new(4).stroked(2).foreground_color(colour::primary()),
                            RotaryState::Captive => RoundedRectangle::new(4).stroked(2).foreground_color(colour::primary_fixed())
                        })
            )
                .content_shape(Rectangle.corner_radius(4))
        },
    )
}
```

#L.flex-row(
  class: "picture-like",
  figure(
    image("../assets/images/scooter/Pasted image 20260808164900.png"),
    caption: [What the above code renders to],
  ),
  figure(
    image("../assets/images/scooter/Pasted image 20260808165048.png"),
    caption: [The homescreen view],
  ),
)


The flexbox layout made building the homescreen also very easy, I know it's quite overkill for static content on a fixed
size screen, but it saves me having to position elements manually.

There was only one problem with Buoyant: the MCU has only 32k of RAM, which is nowhere near enough for a framebuffer.
This means when Buoyant draws a frame it has to draw every single component to the display; the pixels with text on in
the above homescreen view would be drawn three times: First the background, then the box, and finally the text. Since we
don't have a framebuffer we also need to send many more repositioning commands to the display. The end result is that
the display flickers so much that it is unusable. The solution is to only redraw the components that change, and
thankfully rust made updating Buoyant to support this relatively pain free.

A naïve solution to tracking what needs to redraw is to keep track of a bounding rectangle, which starts empty and, when
a component is marked dirty, is expanded to surround its previous self and the rectangle containing the dirty component.
But this isn't good if you have two components at opposite ends of the screen that both update on the same frame. My
solution to this is to instead insert the bounding boxes of dirtied components into a
quadtree#sidenote-mark(<quadtree>), which allows the areas that need to be redrawn (and therefore the components that
need to redraw) to be tracked more precisely. My solution goes a step further and tracks two quadtrees: one tracks dirty
regions and one tracks 'overdrawn' regions. A component is marked as changed if a property changes, or its bounding box
overlaps with either tree before checking its children, or if its bounding box overlaps with the dirty tree after
checking its children. When a component changes, its prior bounding box is added to the dirty tree, and its new bounding
box is added to the 'overdrawn' tree. When a rectangle is added to the overdrawn tree, any rectangles contained within
are removed from the dirty tree. If a node redraws but doesn't change its bounding box, then any elements behind it
don't need to also redraw, but we do want its children to redraw.

#sidenote(
  <quadtree>,
)[An implementation backed by a fixed size array, so that we need no allocations. If the quadtree
  is full, an inserted rect combines with the closest rect already in the tree.]

#html.div(class: "flex justify-center")[
  #html.div(class: "md:w-1/2")[
    #figure(caption: [The display partially updating, when the seconds counter updates, it doesn't force the entire screen to flash.])[
      #video("../assets/images/scooter/PXL_20260908_131712135.TS~2.mp4")
    ]
  ]
]

There's only one large downside to Buoyant: While it puts in quite some effort to minimise its use of generics, each
`Stack` node is still parameterised by the types of all the child nodes, which means the fully expanded types start to look like this:

```rust
<buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::match_view::OneOf4<buoyant::view::modifier::map_event::MapEvent<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::capturing::Lens<buoyant::view::hstack::HStack<(buoyant::view::capturing::Lens<buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<&str,
glyphr::font::Font>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::locked::pin_piece::{closure#1}, scooter_display::ui::view::locked::pin_piece::{closure#0}>,
scooter_display::ui::view::locked::pin_entry::{closure#0}>,
buoyant::view::capturing::Lens<buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<&str,
glyphr::font::Font>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::locked::pin_piece::{closure#1}, scooter_display::ui::view::locked::pin_piece::{closure#0}>,
scooter_display::ui::view::locked::pin_entry::{closure#1}>,
buoyant::view::capturing::Lens<buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<&str,
glyphr::font::Font>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::locked::pin_piece::{closure#1}, scooter_display::ui::view::locked::pin_piece::{closure#0}>,
scooter_display::ui::view::locked::pin_entry::{closure#2}>,
buoyant::view::capturing::Lens<buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<&str,
glyphr::font::Font>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::locked::pin_piece::{closure#1}, scooter_display::ui::view::locked::pin_piece::{closure#0}>,
scooter_display::ui::view::locked::pin_entry::{closure#3}>)>, scooter_display::ui::view::locked::view::{closure#0}>,
buoyant::view::button::Button<scooter_display::ui::view::locked::view::{closure#2},
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<&str,
glyphr::font::Font>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::locked::view::{closure#1}>)>>, scooter_display::ui::view::locked::view::{closure#3}, ()>,
buoyant::view::modifier::captures_event::CapturesEvent<buoyant::view::vstack::VStack<(buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::hstack::HStack<(buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rounded_rectangle::RoundedRectangle>>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::foreach::ForEachView<3: usize,
scooter_display::ui::view::home::TimePieceToShow,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 3: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>, scooter_display::ui::view::home::header::{closure#3},
buoyant::view::foreach::Horizontal>>)>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rectangle::Rectangle>,
buoyant::view::modifier::erase_captures::EraseCaptures<buoyant::view::vstack::VStack<(buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::hstack::HStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 3: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 2: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>)>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rectangle::Rectangle>>,
buoyant::view::modifier::padding::Padding<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::hstack::HStack<(buoyant::view::vstack::VStack<(buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::fixed_frame::FixedFrame<buoyant::view::modifier::padding::Padding<buoyant::view::hstack::HStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 8: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::fixed_frame::FixedFrame<buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 8: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>)>,
buoyant::view::vstack::VStack<(buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::fixed_frame::FixedFrame<buoyant::view::modifier::padding::Padding<buoyant::view::hstack::HStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 8: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::fixed_frame::FixedFrame<buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 8: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>)>)>>>)>>)>,
scooter_display::ui::view::home::view::{closure#0}>,
buoyant::view::modifier::captures_event::CapturesEvent<buoyant::view::modifier::padding::Padding<buoyant::view::modifier::popover::Popover<buoyant::view::scroll_view::ScrollView<buoyant::view::foreach::ForEachView<3:
usize, scooter_display::ui::view::settings::Setting,
buoyant::view::match_view::OneOf2<buoyant::view::empty_view::EmptyView,
buoyant::view::button::Button<scooter_display::ui::view::settings::setting_entry::{closure#1},
buoyant::view::modifier::padding::Padding<buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::padding::Padding<buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>)>>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>>,
scooter_display::ui::view::settings::setting_entry::{closure#0}>>,
scooter_display::ui::view::settings::view::{closure#1}>>,
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::vstack::VStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>, buoyant::view::spacer::Spacer,
buoyant::view::match_view::OneOf2<buoyant::view::vstack::VStack<(buoyant::view::text::Text<&str, glyphr::font::Font>,
buoyant::view::hstack::HStack<(buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 4: usize]>>, glyphr::font::Font>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::settings::number_rotary<scooter_display::ui::view::settings::speed_limit_rotary_handler::{closure#0}>::{closure#1},
scooter_display::ui::view::settings::number_rotary<scooter_display::ui::view::settings::speed_limit_rotary_handler::{closure#0}>::{closure#0}>,
buoyant::view::text::Text<&str, glyphr::font::Font>,
buoyant::view::rotary::Rotary<buoyant::view::modifier::content_shape::ContentShape<buoyant::view::modifier::background::BackgroundView<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::modifier::padding::Padding<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 4: usize]>>, glyphr::font::Font>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::match_view::OneOf3<buoyant::view::empty_view::EmptyView,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::shape::Stroked<buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::settings::number_rotary<scooter_display::ui::view::settings::speed_limit_rotary_handler::{closure#0}>::{closure#1},
scooter_display::ui::view::settings::number_rotary<scooter_display::ui::view::settings::speed_limit_rotary_handler::{closure#0}>::{closure#0}>)>)>,
buoyant::view::foreach::ForEachView<4: usize, scooter_display::ui::view::settings::SettingEntry,
buoyant::view::button::Button<scooter_display::ui::view::settings::generic_setting_screen::{closure#0}::{closure#1},
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::settings::generic_setting_screen::{closure#0}::{closure#0}>,
scooter_display::ui::view::settings::generic_setting_screen::{closure#0}>>, buoyant::view::spacer::Spacer,
buoyant::view::button::Button<scooter_display::ui::view::settings::view::{closure#2}::{closure#1},
buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::padding::Padding<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rounded_rectangle::RoundedRectangle>,
scooter_display::ui::view::settings::view::{closure#2}::{closure#0}>)>>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rounded_rectangle::RoundedRectangle>>>,
scooter_display::ui::view::settings::view::{closure#3}>,
buoyant::view::modifier::captures_event::CapturesEvent<buoyant::view::modifier::padding::Padding<buoyant::view::scroll_view::ScrollView<buoyant::view::foreach::ForEachView<17:
usize, scooter_display::ui::view::info::Info,
buoyant::view::button::Button<scooter_display::ui::view::info::info_entry::{closure#1},
buoyant::view::modifier::padding::Padding<buoyant::view::modifier::background_color::BackgroundColor<buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::padding::Padding<buoyant::view::hstack::HStack<(buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<&str,
glyphr::font::Font>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565>,
buoyant::view::modifier::flex_frame::FlexFrame<buoyant::view::modifier::foreground_color::ForegroundStyle<buoyant::view::text::Text<heapless::string::StringInner<u8,
heapless::vec::storage::VecStorageInner<[core::mem::maybe_uninit::MaybeUninit<u8>; 8: usize]>>, glyphr::font::Font>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565>>)>>>, embedded_graphics_core::pixelcolor::rgb_color::Rgb565,
buoyant::view::shape::rounded_rectangle::RoundedRectangle>>, scooter_display::ui::view::info::info_entry::{closure#0}>,
scooter_display::ui::view::info::view::{closure#0}>>>, scooter_display::ui::view::info::view::{closure#1}>>>,
embedded_graphics_core::pixelcolor::rgb_color::Rgb565, buoyant::view::shape::rectangle::Rectangle> as
buoyant::view::ViewLayout<scooter_display::ui::state::State>>::layout::<buoyant::environment::DefaultEnvironment>
```

This of course isn't ideal as it means we're going to be generating an absolute ton of code bloat from all the possible
instantiations, as a result, the code generated by Buoyant takes up easily 80% of the 190KB size of the binary :/
Currently the code fits, but it's quite limiting, and I don't really have space to add any more features. I've started
working on a new library that I hope should improve on this, but it's not going to be done any time soon.

== Finally getting this code onto the real thing

So far, all this development has been happening on the cracked open display unit using a debugger, with the application
starting from 0x800000 so that no code was running before mine, but when running on a real scooter, the application base
is at 0x8008000. This is normally fine; the initialisation code of the application firmware just needs to be configured
to configure the interrupt vector base address, so that the bootloader's interrupts aren't used instead of yours. It was
almost the case that this was all that was needed with my firmware, but for some reason, when the bootloader was allowed
to run the CAN bus would no longer receive messages; instead it would repeatedly throw framing errors. After a lot of
head bashing and printing of register contents, it dawned on me that the bootloader was enabling some clocks and
initialising some peripherals. When a clock is running it becomes impossible to change things like the divisor, this
leads to my clock initialisation code not being able to set the correct divisor or clock source for the CAN peripheral,
leading to it calculating its timing parameters with the wrong clock frequency...

The solution ends up being this horrible dance that needs to be done:

```rust
    let dp = unsafe { hal::pac::Peripherals::steal() };
    let mut cp = cortex_m::peripheral::Peripherals::take().unwrap();

    // Bootloader jumps to us with some clocks enabled, so the first thing
    // we do is tear everything down.

    // There might be a better way, and some of these are probably not necessary.
    dp.CRM.ctrl().reset();
    dp.CRM.cfg().reset();
    dp.CRM.clkint().reset();
    dp.CRM.pll().reset();
    dp.CRM.misc1().modify(|_, w| unsafe {
        w.clkoutdiv()
            .bits(0)
            .hickdiv()
            .bit(false)
            .clkout_sel3()
            .bit(false)
    });

    dp.CRM.apb2en().modify(|_, w| {
        w.iomux()
            .bit(false)
            .gpioa()
            .bit(false)
            .gpiof()
            .bit(false)
            .spi1()
            .bit(false)
    });
    dp.CRM.apb1en().modify(|_, w| w.can1().bit(false));
    dp.CRM.ahben().modify(|_, w| w.dma1().bit(false));

    dp.CRM
        .ctrl()
        .modify(|_, w| w.pllen().clear_bit().hexten().clear_bit());

    dp.CRM.cfg().modify(|_, w| unsafe {
        w.pllrcs()
            .clear_bit()
            .pllmult3_0()
            .bits(0)
            .pllmult5_4()
            .bits(0)
    });

    // finally we can now configure our clocks
    let crm = dp.CRM.constrain();

    let clocks = crm
        .cfgr
        .use_hext(8.MHz())
        .sclk(96.MHz()) // can seems to fall over if this is clocked any higher
        .pclk1(48.MHz())
        .pclk2(48.MHz())
        .freeze();
```

With this setup code in place, the scooter display unit is now able to correctly boot into the bootloader, which boots
the main application, which then reconfigures the clocks appropriately, sets up the required peripherals, and then
starts up all the tasks. If you're interested in the source code, you can find it here: https://github.com/simmsb/scooter-display

#html.div(class: "flex justify-center")[
  #html.div(class: "md:w-1/2")[
    #figure(caption: [The scooter in use. Note the huge range prediction due to the wheels spinning freely])[
      #video("../assets/images/scooter/PXL_20260908_131510935.TS.mp4")
    ]
  ]
]

== The future

I'm very happy with how this project went, I was actually quite surprised at how easy it was to build firmware with a
nice interface that's also reliable enough for me to use daily. I think I'm going to work on other things now as I think
I've been working on this project for over 6 months now. But there's still lots that I could do, including rewriting the
motor controller firmware, and adding some data logging capabilities (it would be nice to see a graph of battery against
distance travelled).

// Local Variables:
// typst-image-dir: "../assets/images/scooter/"
// fill-column: 120
// jinx-local-words: "bootloader bootloader's"
// End:
