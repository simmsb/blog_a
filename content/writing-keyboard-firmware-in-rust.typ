#import "/templates/base.typ": video
#import "/templates/post.typ": post

#let args = (
  title: "Oxidating all the microcontrollers",
  date: datetime(year: 2022, month: 6, day: 20),
  slug: "writing-keyboard-firmware-in-rust",
  tags: ("programming", "rust", "keyboards"),
  summary: "I put rust on my keyboards",
)

#show: post.with(..args)

#image("../assets/images/rust-keyboard/_20220616_183742screenshot.png")

Most user-programmable mechanical keyboards use an embedded OS named #link("https://github.com/qmk/qmk_firmware/")[QMK], which
has support for both AVR and ARM microcontrollers. Some keyboards alternatively
use #link("https://github.com/zmkfirmware/zmk")[ZMK] which adds support for Bluetooth.

However as it turns out, the Rust-on-ARM story is pretty fleshed out with the
following projects:

- #link("https://github.com/knurling-rs/defmt")[knurling-rs/defmt]: Provides debug formatting/logging.
- #link("https://github.com/knurling-rs/probe-run")[knurling-rs/probe-run]: Automates flashing microcontrollers and collecting
  logs.
- #link("https://github.com/rust-embedded/cortex-m")[rust-embedded/cortex-m]: Provides access to ARM Cortex registers,
  peripherals, etc.
- #link("https://github.com/rtic-rs/cortex-m-rtic")[rtic-rs/cortex-m-rtic]: Provides support for concurrently executing tasks
  using interrupts.
- #link("https://github.com/embassy-rs/embassy")[embassy-rs/embassy]: Provides support for concurrently executing tasks using
  the rust async infrastructure, along with async USB/UART/I2C interfaces.

For this I built an ergo keyboard (#link("https://github.com/foostan/crkbd")[the corne v3]) with RGB LEDs and OLED
displays. For the controller(s) I went with #link("https://nicekeyboards.com/nice-nano")[nice!nano]s, which use the nRF52840
SoC. The nRF52840 supports Bluetooth, but as I don't move the keyboard often, I
decided to assume the keyboard will be always wired.

This was my first time writing for a microcontroller using something other than
Arduino and it was an incredibly fluid experience. I spent a grand total of zero
seconds debugging memory related problems, all bugs I had ended up being logic
issues that were easily fixed by logging with `defmt`.

== Programming <programming>

=== Embassy <embassy>

Initially I attempted using RTIC to provide support for concurrent tasks,
however RTIC requires you to manage setting up interrupts (for UART, I2C, etc)
yourself, and quickly this got annoying.

After finding #link("https://github.com/embassy-rs/embassy")[embassy] I quickly ported my code over to use it. Embassy uses
rust's async machinery to allow for true tasks that run forever (in rtic each
task is a function triggered by an interrupt). Embassy provides async compatible
interfaces for USB, UART, and I2C too.

Creating a UART interface in Embassy is as simple as:

```rust
let uart_config = uarte::Config::default();
let irq = interrupt::take!(UARTE0_UART0);
let uart = uarte::Uarte::new(p.UARTE0, irq, p.P0_08, p.P1_04, uart_config);

uart.write(b"hello world").await?;
let mut buf = [0u8; 1];
uart.read(&mut buf).await?;
```

To communicate between tasks, I use the #link("https://docs.embassy.dev/embassy/git/thumbv7em-none-eabihf/channel/channel/struct.Channel.html")[channel] provided by embassy to have the
producer task wait for the consumer task to process messages if the queue is
full.

=== Keyberon <keyberon>

The most important part of the keyboard is having it, well, work as a keyboard.
Luckily I don't have to implement all the state management of a keyboard myself,
as the #link("https://github.com/TeXitoi/keyberon")[TeXitoi/keyberon] project conveniently exists.

Keyberon was incredibly easy to work with as it splits itself up into the few
logically separated components needed for a keyboard:

- Matrix polling
- Key debouncing
- Key event processing
- HID event generation

To get Keyberon working I simply had to:

==== Specify matrix pins and construct the matrix struct <specify-matrix-pins-and-construct-the-matrix-struct>

I used a macro for this as it requires that the gpio pin values are partially
moved from the peripherals struct (this allows the compiler to ensure there is
only one user of each pin at compile time)

```rust
macro_rules! build_matrix {
    ($p:ident) => {{
        use embassy_nrf::gpio::{Input, Level, OutputDrive, Pin, Pull};
        use keyberon::matrix::Matrix;
        Matrix::new(
            [
                Input::new($p.P0_31.degrade(), Pull::Up),
                Input::new($p.P0_29.degrade(), Pull::Up),
                Input::new($p.P0_02.degrade(), Pull::Up),
                Input::new($p.P1_15.degrade(), Pull::Up),
                Input::new($p.P1_13.degrade(), Pull::Up),
                Input::new($p.P1_11.degrade(), Pull::Up),
            ],
            [
                Output::new($p.P0_22.degrade(), Level::High, OutputDrive::Standard),
                Output::new($p.P0_24.degrade(), Level::High, OutputDrive::Standard),
                Output::new($p.P1_00.degrade(), Level::High, OutputDrive::Standard),
                Output::new($p.P0_11.degrade(), Level::High, OutputDrive::Standard),
            ],
        )
        .unwrap()
    }};
}
```

==== Specify my keyboard layout <specify-my-keyboard-layout>

Keyberon provides a nice macro for doing this. In the same #link("https://github.com/simmsb/keyboard/blob/main/keyboard/src/layout.rs")[file] I also declare
the hold-taps and chords I want to use.

```rust
pub static LAYERS: Layers  = keyberon::layout::layout! {
    {
        ['`' Q W E R T Y U I O P '\''],
        [LShift A S D F G H J K L ; RShift],
        [LCtrl Z X C V B N M , . / RCtrl],
        [n n n LGui {ALT_TAB} {L1_SP} {L2_SP} Enter BSpace n n n],
        [Escape {m(&[KeyCode::LAlt, KeyCode::X])} {m(&[KeyCode::Space, KeyCode::Grave])} Delete < {m(&[KeyCode::LShift, KeyCode::SColon])} > '\\' / '"' '\'' '_'],
    }
    {
        ['`' ! @ '{' '}' | '`' ~ '\\' n '"'  n],
        [ t  # $ '(' ')' n  +  -  /   * '\'' t],
        [ t  % ^ '[' ']' n  &  =  ,   . '_'  t],
        [n n n LGui LAlt =  = Tab BSpace n n n],
        [n n n n    n    n  n n   n      n n n],
    }
    {
        [n Kb1 Kb2 Kb3 Kb4 Kb5 Kb6 Kb7 Kb8 Kb9 Kb0 n],
        [t F1  F2  F3  F4  F5  Left Down Up Right VolUp t],
        [t F6  F7  F8  F9  F10 PgDown {m(&[KeyCode::LCtrl, KeyCode::Down])} {m(&[KeyCode::LCtrl, KeyCode::Up])} PgUp VolDown t],
        [n n n F11 F12 t t RAlt End n n n],
        [n n n n   n   n n n    n   n n n],
    }
};
```

==== Poll the matrix <poll-the-matrix>

Keyberon provides the matrix struct, but won't handle polling the matrix at an
interval for us. For that I use an embassy task to poll the matrix every
`POLL_PERIOD` and feed the results through the debouncer and chording engine.
The processed key events are then pushed to a channel for processing by the
layout task.

```rust
#[embassy::task]
async fn keyboard_poll_task(
    mut matrix: Matrix<Input<'static, AnyPin>, Output<'static, AnyPin>, COLS_PER_SIDE, ROWS>,
    mut debouncer: Debouncer<[[bool; COLS_PER_SIDE]; ROWS]>,
    mut chording: Chording<{ keyboard_thing::layout::NUM_CHORDS }>,
) {
    loop {
        let events = debouncer
            .events(matrix.get().unwrap())
            .collect::<heapless::Vec<_, 8>>();

        for event in &events {
            for chan in KEY_EVENT_CHANS {
                let _ = chan.try_send(*event);
            }
        }

        let events = chording.tick(events);

        let count = events.iter().filter(|e| e.is_press()).count() as u32;
        TOTAL_LHS_KEYPRESSES.fetch_add(count, core::sync::atomic::Ordering::Relaxed);

        for event in events {
            PROCESSED_KEY_CHAN.send(event).await;
        }

        Timer::after(POLL_PERIOD).await;
    }
}
```

==== Push events through the layout <push-events-through-the-layout>

As before with the matrix, we decide when the layout state should be updated.
For that another task is used to update the matrix state when a key is pressed
or released. This task also receives the key events from the other half.

```rust
#[embassy::task]
async fn keyboard_event_task(layout: &'static Mutex<ThreadModeRawMutex, Layout>) {
    loop {
        let event = PROCESSED_KEY_CHAN.recv().await;
        let mut count = if event.is_press() { 1 } else { 0 };
        if event.is_press() {
            KEYPRESS_EVENT.set();
        }
        interacted();
        {
            let mut layout = layout.lock().await;
            layout.event(event);
            while let Ok(event) = PROCESSED_KEY_CHAN.try_recv() {
                layout.event(event);
                count += if event.is_press() { 1 } else { 0 };
            }
        }
        TOTAL_KEYPRESSES.fetch_add(count, core::sync::atomic::Ordering::Relaxed);
    }
}
```

==== Extract keycode events and submit to the computer <extract-keycode-events-and-submit-to-the-computer>

To extract keycode events we use another task that extracts which keys are
currently pressed every 1ms and submits the event to the task handling the USB
HID messaging.

```rust
#[embassy::task]
async fn layout_task(layout: &'static Mutex<ThreadModeRawMutex, Layout>) {
    let mut last_report = None;
    loop {
        {
            let mut layout = layout.lock().await;
            layout.tick();

            let collect = layout
                .keycodes()
                .filter_map(|k| Keyboard::try_from_primitive(k as u8).ok())
                .collect::<heapless::Vec<_, 24>>();

            if last_report.as_ref() != Some(&collect) {
                last_report = Some(collect.clone());
                HID_CHAN.send(NKROBootKeyboardReport::new(&collect)).await;
            }
        }

        Timer::after(Duration::from_millis(1)).await;
    }
}
```

==== Tie everything together <tie-everything-together>

First the required things are initialized, then we can start the tasks that
perform all the keyboard processing.

```rust
let matrix = keyboard_thing::build_matrix!(p);
let debouncer = Debouncer::new(
    [[false; COLS_PER_SIDE]; ROWS],
    [[false; COLS_PER_SIDE]; ROWS],
    DEBOUNCER_TICKS,
);
let chording = Chording::new(&keyboard_thing::layout::CHORDS);

let layout = forever!(Mutex::new(Layout::new(&keyboard_thing::layout::LAYERS)));

spawner
    .spawn(keyboard_poll_task(matrix, debouncer, chording))
    .unwrap();
spawner.spawn(keyboard_event_task(layout)).unwrap();
spawner.spawn(layout_task(layout)).unwrap();
```

=== NeoPixels <neopixels>

My Corne kit came with per-key and under-glow neopixels, so why not use them!

Fortunately the #link("https://github.com/jamesmunns/nrf-smartled")[jamesmunns/nrf-smartled] library exists for controlling neopixels
by #strike[ab]​using the PWM peripheral on the nRF52840. Now to take advantage of all
64Mhz we just need to define the positions of each LED (they're connected serially):

```rust
// underglow LEDs are left to right
#[rustfmt::skip]
pub const UNDERGLOW_LED_POSITIONS: [(u8, u8); UNDERGLOW_LEDS] = [
    // top row: 1, 2, 3
    (0, 1), (2, 1), (4, 1),
    // bottom row: 4, 5, 6
    (4, 2), (2, 3), (0, 3),
];

// switch leds are bottom to top
#[rustfmt::skip]
pub const SWITCH_LED_POSITIONS: [(u8, u8); SWITCH_LEDS] = [
    // first column: 7, 8, 9, 10
    (3, 5), (2, 5), (1, 5), (0, 5),
    // second column: 11, 12, 13, 14
    (0, 4), (1, 4), (2, 4), (3, 4),
    // third column: 15, 16, 17, 18
    (3, 3), (2, 3), (1, 3), (0, 3),
    // fourth column: 19, 20, 21
    (0, 2), (1, 2), (2, 2),
    // fifth column: 22, 23, 24
    (2, 1), (1, 1), (0, 1),
    // sixth column: 25, 26, 27
    (0, 0), (1, 0), (2, 0)
];
```

And now we can create a fancy rainbow effect:

```rust
pub fn rainbow_single(x: u8, y: u8, offset: u8) -> Hsv {
    Hsv {
        hue: x
            .wrapping_mul(6)
            .wrapping_add(y.wrapping_mul(2))
            .wrapping_add(offset),
        sat: 255,
        val: 127,
    }
}

pub fn rainbow(offset: u8) -> impl Iterator<Item = RGB8> {
    colour_gen(move |x, y| hsv2rgb(rainbow_single(x, y, offset)))
}
```

And use an embassy task to update and render it at 30fps.

```rust
#[embassy::task]
async fn led_task(mut leds: Leds) {
    let fps = 30;
    let mut tapwaves = TapWaves::new();
    let mut ticker = Ticker::every(Duration::from_millis(1000 / fps));
    let mut counter = WrappingID::<u16>::new(0);

    loop {
        while let Ok(event) = LED_KEY_LISTEN_CHAN.try_recv() {
            tapwaves.update(event);
        }

        tapwaves.tick();

        leds.send(tapwaves.render(|x, y| rainbow_single(x, y, counter.get() as u8)));

        counter.inc();

        if (counter.get() % 128) == 0 {
            let _ = COMMAND_CHAN.try_send((
                DomToSub::ResyncLeds(counter.get()),
                Duration::from_millis(5),
            ));
        }

        ticker.next().await;
    }
}
```

I also added in animated waves that emanate from each key when pressed, I'm
really making full use of the nRF's FP unit here.

#video("../assets/images/rust-keyboard/video_2022-06-17_18-08-42.mp4")

=== OLEDs <oleds>

The Corne has support for a 128x32 display on each side, enough space that I'm
struggling to decide what to put on each.

For the right side I have some metrics displayed: the total number of
keypresses, the current keypresses per second, and the number of seconds the
keyboard has been on. I also have a sliding display of keypresses at the bottom:

#video("../assets/images/rust-keyboard/doc_2022-06-20_16-05-18.mp4")

And for the left side I currently have a badly drawn bongo cat, I'm still
thinking of what to use the remaining 96x32 pixels for.

#video("../assets/images/rust-keyboard/doc_2022-06-20_16-05-08.mp4")

To control the OLED displays, I use #link("https://github.com/jamwaffles/ssd1306")[jamwaffles/ssd1306] which handles writing out
a buffer the display, and #link("https://github.com/embedded-graphics/embedded-graphics")[embedded-graphics] to draw text, images, and other
geometry.

I use the following to initialize the display and handle turning the display off
during periods of inactivity:

```rust
type OledDisplay<'a, T> =
    Ssd1306<I2CInterface<Twim<'a, T>>, DisplaySize128x32, BufferedGraphicsMode<DisplaySize128x32>>;

pub struct Oled<'a, T: Instance> {
    status: bool,
    display: OledDisplay<'a, T>,
}

impl<'a, T: Instance> Oled<'a, T> {
    pub fn new(twim: Twim<'a, T>) -> Self {
        let i2c = I2CDisplayInterface::new(twim);
        let display = Ssd1306::new(i2c, DisplaySize128x32, DisplayRotation::Rotate0)
            .into_buffered_graphics_mode();
        Self {
            status: true,
            display,
        }
    }

    pub async fn init(&mut self) -> Result<(), DisplayError> {
        self.display.set_rotation(DisplayRotation::Rotate90).await?;
        self.display.set_brightness(Brightness::BRIGHTEST).await?;
        self.display.init().await?;
        Ok(())
    }

    // ...
}

pub const OLED_TIMEOUT: Duration = Duration::from_secs(30);
static INTERACTED_EVENT: Event = Event::new();

pub fn interacted() {
    INTERACTED_EVENT.set();
}

async fn turn_off(oled: &Mutex<ThreadModeRawMutex, Oled<'_, impl Instance>>) {
    Timer::after(OLED_TIMEOUT).await;

    let _ = oled.lock().await.set_off().await;

    turn_on(oled).await;
}

async fn turn_on(oled: &Mutex<ThreadModeRawMutex, Oled<'_, impl Instance>>) {
    INTERACTED_EVENT.wait().await;

    let _ = oled.lock().await.set_on().await;
}

pub async fn display_timeout_task<'a, T: Instance>(oled: &Mutex<ThreadModeRawMutex, Oled<'a, T>>)
where
    Twim<'a, T>: I2c<u8>,
{
    loop {
        select(turn_on(oled), turn_off(oled)).await;
    }
}
```

To then generate the content for the displays, I use the following (for the
rhs):

```rust
async fn render_normal(&mut self) {
    let character_style = MonoTextStyle::new(&PROFONT_9_POINT, BinaryColor::On);
    let textbox_style = TextBoxStyleBuilder::new()
        .height_mode(embedded_text::style::HeightMode::FitToText)
        .alignment(embedded_text::alignment::HorizontalAlignment::Justified)
        .paragraph_spacing(6)
        .build();

    let bounds = Rectangle::new(Point::zero(), Size::new(32, 0));

    self.buf.clear();

    let kp = TOTAL_KEYPRESSES.load(core::sync::atomic::Ordering::Relaxed);
    let cps = AVERAGE_KEYPRESSES.load(core::sync::atomic::Ordering::Relaxed);
    let cps = f32::trunc(cps * 10.0) / 10.0;
    let mut fp_buf = dtoa::Buffer::new();
    let cps = fp_buf.format_finite(cps);

    let _ = uwriteln!(&mut self.buf, "kp:");
    let _ = uwriteln!(&mut self.buf, "{}", kp);
    let _ = uwriteln!(&mut self.buf, "cps:");
    let _ = uwriteln!(&mut self.buf, "{}/s", cps);
    let _ = uwriteln!(&mut self.buf, "tick:");
    let _ = uwriteln!(&mut self.buf, "{}", self.ticks);

    let text_box =
        TextBox::with_textbox_style(&self.buf, bounds, character_style, textbox_style);

    let lines = {
        let samples = self.sample_buffer.lock().await;
        samples
            .oldest_ordered()
            .enumerate()
            .map(|(idx, height)| {
                Line::new(
                    Point::new(idx as i32, 128 - (*height as i32).clamp(0, 16)),
                    Point::new(idx as i32, 128),
                )
                .into_styled(PrimitiveStyle::with_stroke(BinaryColor::On, 1))
            })
            .collect::<heapless::Vec<_, 32>>()
    };

    let _ = self
        .oled
        .lock()
        .await
        .draw(move |d| {
            let _ = text_box.draw(d);
            for line in lines {
                let _ = line.draw(d);
            }
        })
        .await;
}
```

=== Inter-board communication <inter-board-communication>

Since I'm not using Bluetooth, the right side of the split needs to communicate
with the left side, there are a few ways to do this but I went with a UART as it
easily allows both sides to send messages to the other.

However a UART has no provisions for error checking (outside of a parity bit) or
framing so I have to do that myself.

To handle encoding and decoding of messages I use #link("https://github.com/jamesmunns/postcard")[jamesmunns/postcard] which
conveniently also handles framing and failure recovery through the use of #link("https://en.wikipedia.org/wiki/Consistent_Overhead_Byte_Stuffing")[COBS]

To ensure message delivery a uuid and checksum is attached to each command, when
one side receives a message and validates the checksum, an `Ack` message with
the same uuid is sent back to the other side. After a command is sent, the
keyboard waits a period of time for an Ack before considering the message to
have not been received. This period is variable depending on the message sent,
keypress events have a longer timeout as duplicated keypresses aren't a good
thing, messages that can tolerate duplication are sent with a lower timeout to
decrease latency.

The messages sent between sides are defined as plain rust enums that derive
#html.elem("span", attrs: ("class": "inline-src language-rust", "data-lang": "rust"))[`serde::Serialize`] and #html.elem("span", attrs: ("class": "inline-src language-rust", "data-lang": "rust"))[`serde::Deserialize`]:

```rust
#[derive(Serialize, Deserialize, Eq, PartialEq, Format, Hash, Clone)]
pub enum DomToSub {
    ResyncLeds(u16),
    Reset,
    SyncKeypresses(u16),
    WritePixels {
        row: u8,
        data_0: [u8; 4],
        data_1: [u8; 4],
    },
}

#[derive(Serialize, Deserialize, Eq, PartialEq, Debug, Format, Hash, Clone)]
pub enum SubToDom {
    KeyPressed(u8),
    KeyReleased(u8),
}
```

These messages are then wrapped in the structs defined here:

```rust
#[derive(Serialize, Deserialize, defmt::Format, Debug)]
pub struct Command<T> {
    pub uuid: u8,
    pub csum: u8,
    pub cmd: T,
}

pub fn csum<T: Hash>(v: T) -> u8 {
    let mut hasher = StableHasher::new(fnv::FnvHasher::default());
    v.hash(&mut hasher);
    let checksum = hasher.finish();

    let bytes = checksum.to_le_bytes();

    bytes.iter().fold(0, core::ops::BitXor::bitxor)
}

impl<T: Hash> Command<T> {
    pub fn new(cmd: T) -> Self {
        static UUID_GEN: AtomicU8 = AtomicU8::new(0);
        let uuid = UUID_GEN.fetch_add(1, core::sync::atomic::Ordering::SeqCst);
        let csum = csum((&cmd, uuid));
        Self { uuid, csum, cmd }
    }

    /// validate the data of the command
    pub fn validate(&self) -> bool {
        let csum = csum((&self.cmd, self.uuid));
        csum == self.csum
    }

    pub fn ack(&self) -> Ack {
        let csum = csum(self.uuid);
        Ack {
            uuid: self.uuid,
            csum,
        }
    }
}

#[derive(Serialize, Deserialize, defmt::Format, Debug)]
pub struct Ack {
    pub uuid: u8,
    pub csum: u8,
}

#[derive(Serialize, Deserialize, defmt::Format, Debug)]
#[repr(u8)]
pub enum CmdOrAck<T> {
    Cmd(Command<T>),
    Ack(Ack),
}

impl Ack {
    pub fn validate(self) -> Option<Self> {
        let csum = csum(self.uuid);
        if csum == self.csum {
            Some(self)
        } else {
            None
        }
    }
}
```

And then are serialized with postcard and transmitted to the other side:

```rust
async fn task(self) {
    loop {
        let val = self.mix_chan.recv().await;

        let mut buf = [0u8; BUF_SIZE];
        if let Ok(buf) =
            postcard::serialize_with_flavor(&val, Cobs::try_new(Slice::new(&mut buf)).unwrap())
        {
            let r = self.tx.write(buf).await;
            debug!("Transmitted {:?}, r: {:?}", val, r);
        }
    }
}
```

== Other dumb things <other-dumb-things>

Okay so I have a keyboard running firmware on rust, oh and I can also talk to it
over USB serial in the same way each half talks to the other. What can I do?

=== Metrics <metrics>

With a little bit of code on the keyboard we can have it reply with the keypress
counter when queried:

```rust
#[embassy::task]
async fn usb_serial_task(mut class: CdcAcmClass<'static, UsbDriver>) {
    loop {
        let in_chan: &mut Channel<ThreadModeRawMutex, u8, 128> = forever!(Channel::new());
        let out_chan: &mut Channel<ThreadModeRawMutex, u8, 128> = forever!(Channel::new());
        let msg_out_chan: &mut Channel<ThreadModeRawMutex, HostToKeyboard, 16> =
            forever!(Channel::new());
        let msg_in_chan: &mut Channel<ThreadModeRawMutex, (KeyboardToHost, Duration), 16> =
            forever!(Channel::new());
        class.wait_connection().await;
        let mut wrapper = UsbSerialWrapper::new(&mut class, &*in_chan, &*out_chan);
        let mut eventer = Eventer::new(&*in_chan, &*out_chan, msg_out_chan.sender());

        let handle = async {
            loop {
                match msg_out_chan.recv().await {
                    HostToKeyboard::RequestStats => {
                        msg_in_chan
                            .send((
                                KeyboardToHost::Stats {
                                    keypresses: TOTAL_KEYPRESSES
                                        .load(core::sync::atomic::Ordering::Relaxed),
                                },
                                Duration::from_millis(5),
                            ))
                            .await;
                    },
                    // ...
                }
            }
        };

        let (e_a, e_b, e_c) = eventer.split_tasks(msg_in_chan);

        select3(wrapper.run(), select3(e_a, e_b, e_c), handle).await;
    }
}
```

And then with the help of another rust program to periodically request the
number of keys pressed from the keyboard (I could do this by keylogging, but
that's not as fun) and export the count to Prometheus, we get a fancy dashboard:

#image("../assets/images/rust-keyboard/_20220620_174320screenshot.png")

=== Video playback <video-playback>

Since the nRF52840 is pretty powerful, we can get away with streaming a video to
the displays of the keyboard. The left side handles receiving frames from the
computer over USB serial, and then sends the frame to its OLED task if the
packet is for the LHS, or forwarded to the RHS otherwise.

The OLED tasks on each side have a channel to receive frames from, when a frame
is received the task stops rendering the original content for a second and
instead displays the received frame.

The result is this:

#video(
  "../assets/images/rust-keyboard/172443165-bc76f323-c769-49e6-9992-025ef0be5f02.mp4",
)

== Links <links>

If you're interested, you can find the source code #link("https://github.com/simmsb/keyboard")[here]

