#import "/templates/post.typ": post

#let args = (
  title: "Squeezing rust onto more things, this time: Flashlights",
  date: datetime(year: 2024, month: 7, day: 7),
  slug: "squeezing-rust-onto-more-things",
  tags: ("programming", "rust", "flashlights", "torches", "tashenlampen"),
  summary: "Putting rust on smaller and smaller things",
)

#show: post.with(..args)

#figure(
  image("../assets/images/torches/rusty_torches.jpg"),
  caption: "These torches are all running on rust",
)

For a while now I have been pretty interested in niche torches that run the
#link("https://github.com/ToyKeeper/anduril")[Andúril] flashlight firmware, which is
written in C and supports many flashlights that use AVR microcontrollers, such
as #link("https://intl-outdoor.com/")[Hank's] and
#link("https://www.firefly-outdoor.com/")[Fireflylite].

In my opinion the standout features of Andúril are:

+ Support for aux LEDs: it's common for these flashlights to have a set of RGB
  LEDs on the front, Andúril supports using these to show the battery voltage
  by changing between 6 colours.
+ Many different mode, some useful like the candle flicker mode, which along
  with the normal mode supports a fading-off timer, and some silly modes like a
  police strobe (flashes the aux lights between red and blue.)
+ Very good thermal and battery voltage handling: the maximum output is smoothy
  adjusted to regulate the temperature of the light, and prevent the battery
  voltage dipping too low.
+ Open source and user flashable: all (or most?) flashlights sold with Andúril
  have accessible flashing pads on the exposed side of the driver circuit
  board, making it easy for people to reflash the firmware.

I dabbled in customising Andúril for about a year while I was also playing
around with writing rust firmware for
keyboards#link("https://github.com/simmsb/rusty-dilemma")[^rusty-keyboards], and in January 2024 I decided to
try squeezing (async) Rust onto an AVR chip. In this case the chip-to-be was an
#link("https://www.microchip.com/en-us/product/attiny1616")[attiny1616] — which has
16kb of flash and 2kb of ram.

= AVR Beginnings <avr-beginnings>

I decided I certainly wanted to use Embassy#link("https://embassy.dev")[^embassy] for writing the firmware,
I had used it previously with my keyboards and loved how easy it made breaking
up the individual tasks that needed to be performed into their own asynchronous
tasks.

However, unlike microcontroller platforms such as nRF, STM32, and RP2040,
Embassy does not have excellent support for AVR. Fortunately, it isn't difficult
to get Embassy up and running on new hardware as long as Rust supports it.
Embassy only needs a hardware specific timer queue implementation, which is used
to schedule tasks for wakeup.

One other slight issue was that there was no Rust peripheral access crate for
the attiny1616, but luckily there was already the
#link("https://github.com/Rahix/avr-device")[avr-device] crate, which has support for
some similar AVR chips, and scripts for generating PACs from machine readable
register description documents.

For those unfamiliar with embedded (and specifically embedded Rust development),
the ecosystem is generally broken down into:

- Peripheral Access Crates (PAC): Provide safe Rust abstractions for reading and
  writing to memory mapped IO registers.
- Hardware Abstraction Libraries (HAL): Provide ergonomic Rust bindings for
  peripherals which often provide fully compile time verified configuration and
  usage of peripherals. (in my opinion HALs in Rust are much nicer to use than
  in other languages, as documentation is easily explored and the type system
  makes sure you're getting everything right)
- Instruction set and runtime support crates: Provide helper functions and the
  necessities to get the CPU going before `main` can run. (e.g. cortex-m(-rt))

After some fiddling I was able to generate the PAC for the attiny1616, and with
that I was able to start poking registers and write functions such as this one
to configure the ADC peripheral:

```rust
impl AdcRegExt for ADC0 {
    // ...

    fn set_c_state(&mut self, prescaler: Self::PreScaler, refsel: Self::RefSel, sampcap: bool) {
        self.ctrlc().modify(|_, w| {
            w.presc()
                .variant(prescaler)
                .refsel()
                .variant(refsel)
                .sampcap()
                .variant(sampcap)
        })
    }
}
```

Also very lucky for me was that someone had already put in the effort of writing
a hardware #link("https://github.com/G33KatWork/atxtiny-hal")[abstraction library] for
tinyAVR microcontrollers (of which the t1616 is a member of), which only needs a
working PAC to provide safe rust abstractions for configuring clocks, GPIO pins,
timers, and the ADC.

Now that we have a PAC for the attiny1616 we can proceed with implementing a
timer queue so that we can get some tasks running.

== Timer queue <timer-queue>

It's a common requirement in many situations that a delay can be inserted
between two operations, and I suppose it's even more common in embedded systems
where simple inputs need to trigger complex outputs and vice-versa. In fact at
the time of writing my flashlight firmware uses eight timeouts and fifteen
sleeps.

Now in many embedded codebases, especially those written using Arduino and such,
it is usual that delays are implemented using busy loops that count cycles until
a period has passed. This is usually because the alternative is to do horrible
things like manually breaking up your code into state machines or use a RTOS
that provides stackful\[^stackful\_tasks\] tasks (and you'll struggle to get a
stackful task scheduler onto an AVR microcontroller with only 2k of RAM).

I'll spare you the usual Rust async spiel about how async functions map to the
Future trait, the gist is that with Rust's async the compiler does the
state-machine-ification for you, so you can write nice sequential code that once
compiled doesn't require wasteful stack switching to achive concurrency. With
all our tasks being state machines, our `sleep(...)` function can just be an
instruction to the scheduler to not schedule our task until the timeout has
elapsed (This is of course how a sleep function works everywhere it isn't a busy
loop). With out sleeping task sleeping, the scheduler can choose to run another
task if one is ready, or if all the tasks are waiting on something the scheduler
can choose to put the microcontroller to sleep instead.

The core of this functionality is the timer queue, and it simply has two jobs:

+ When a task wants to sleep, Embassy passes to the timer queue a
  #link("https://doc.rust-lang.org/nightly/core/task/struct.Waker.html")[`Waker`] and
  a timestamp indicating when the waker should be woken.
+ When this timer is reached, the timer queue should call the `.wake()` method
  of the waker, which does whatever is necessary to mark the task as ready to
  run again.

Embassy models this as a #link("https://docs.rs/embassy-time-queue-driver/0.1.0/embassy_time_queue_driver/index.html")[Trait with a single `schedule_wake`
  method]:

```rust
struct MyTimerQueue{}; // not public!

impl TimerQueue for MyTimerQueue {
    fn schedule_wake(&'static self, at: u64, waker: &Waker) {
        todo!()
    }
}
```

So to implement a timer queue you need only to implement this trait, and some
way to handle waking. On embedded devices there is in general two ways to do this:

+ Have an interrupt fire periodically (say, at 1000Hz), the handler to this
  interrupt can step a counter and then wake up all the tasks which have
  timestamps that are now in the past.

  This solution is simple, but forces the microcontroller to wake up
  periodically even when there's no work to do.

+ Configure a hardware timer to fire an interrupt when the next timer is due,
  then process elapsed timeouts as with (.1)

  This is more complicated as you have to handle cancelling and restarting a
  hardware timer, but allows the system to sleep uninterrupted for longer
  periods of time.


I chose to use a periodic interrupt for the simplicity of implementation, as
there's always the option to switch to dynamically reconfiguring the timer in
the future.

To begin with, we need to define how the state of the timer queue is stored. For
my implementation I store for each queue entry:

```rust
use core::{
    cell::Cell,
    task::Waker,
};

use avr_device::interrupt::{CriticalSection, Mutex};

pub type Time = u32;

const QUEUE_SIZE: usize = 10;

struct Entry {
    at: Time,
    waker: Waker,
}

/// An array of queue entries. The `Mutex<Cell<_>>` here is actually
/// a noop at runtime, and just serves to prove we're inside a
/// critical section when accessing the entries
static ENTRIES: [Mutex<Cell<Option<Entry>>>; QUEUE_SIZE] =
    [const { Mutex::new(Cell::new(None)) }; QUEUE_SIZE];
```

We then need a function to allocate an entry on this timer queue:

```rust

/// Allocate an entry, returning on success the index, and whether
/// there was already an entry for this waker
pub fn allocate(
    /// A handle to a critical section, this proves that interrupts
    /// are disabled while this function is called
    _: CriticalSection,
    /// The waker we're allocating for, used so we only ever have
    /// one entry in the queue for each task/ waker
    waker: &Waker) -> Option<(NonMaxU8, bool)> {
    unsafe {
        for i in 0..QUEUE_SIZE {
            // if this entry is taken, but is allocted for the same
            // waker, return that.
            // this happens when a future tries to sleep again after
            // being woken by something other than a timeout
            if TAKEN[i] && WAKERS[i].as_ref().map_or(false, |w| w.will_wake(waker)) {
                return Some((NonMaxU8(i as u8), true));
            }
        }
        for i in 0..QUEUE_SIZE {
            // otherwise, return the first empty slot
            if !TAKEN[i] {
                TAKEN[i] = true;
                return Some((NonMaxU8(i as u8), false));
            }
        }

        None
    }
}

/// Add a waker to the queue, correctly handles when the
/// waker is already in the queue
pub fn allocate(
    /// A handle to a critical section, this proves that interrupts
    /// are disabled while this function is called
    cs: CriticalSection,
    at: Time,
    waker: &Waker) {

    // do a first pass over the entries to ensure the waker
    // isn't already in the queue
    for entry in &ENTRIES {
        // does rust optimise out the copies here? Ich weiß es nicht
        let entry = entry.borrow(cs);
        let e = entry.replace(None);

        if let Some(mut e) = e {
            // waker is the same, simply store back the earliest time
            if e.waker.will_wake(waker) {
                e.at = at.min(e.at);

                entry.set(Some(e));
                return;
            } else {
                entry.set(Some(e));
            }
        }
    }

    // if the waker isn't already in the queue,
    // find the first unused entry and store it there
    for entry in &ENTRIES {
        let entry = entry.borrow(cs);
        let e = entry.replace(None);

        if e.is_some() {
            entry.set(e);
            continue;
        }

        entry.set(Some(Entry { at, waker: waker.clone() }));

        return;
    }

    // Ideally this could only be hit if we have more tasks
    // than the queue capacity
    panic!("queue full");
}

```

And that's all we need to implement the first half of the timer queue, we just
need to provide an interface for Embassy to use it:

```rust
pub struct AvrTc0EmbassyTimeDriver {}

impl TimerQueue for AvrTc0EmbassyTimeDriver {
    fn schedule_wake(&'static self, at: Time, waker: &Waker) {
        avr_device::interrupt::free(|t| {
            wake_queue::allocate(t, at, waker);
        })
    }
}
```

Now that we can add to our timer queue, we just need to periodically process the
entries and wake up tasks which need waking up. I chose to do this using the
Periodic Interrupt Timer functionality (PIT) of the Real Time Clock (RTC)
peripheral on the AVR:

```rust
pub static TICKS_ELAPSED: Mutex<Cell<Time>> = Mutex::new(Cell::new(0));

#[allow(dead_code)]
const TICKS_PER_COUNT: Time = 1;

/// Check each entry in the queue, if the timer has elapsed,
/// then wake the associated task
pub fn process(ticks_elapsed: Time) {
    for entry in &ENTRIES {
        let w = avr_device::interrupt::free(|cs| {
            let entry = entry.borrow(cs);
            let e = entry.replace(None);

            if let Some(e) = e {
                if e.at <= ticks_elapsed {
                    return Some(e.waker);
                } else {
                    entry.set(Some(e));
                }
            }

            None
        });

        if let Some(w) = w {
            w.wake();
        }
    }
}

// A flag we use to ensure we don't try to process the timer queue
// recursively if handle_tick is entered again somehow
static IN_PROGRESS: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

pub fn mark_in_progress(cs: CriticalSection) -> bool {
    !IN_PROGRESS.borrow(cs).replace(true)
}

pub fn mark_finished(cs: CriticalSection) {
    IN_PROGRESS.borrow(cs).set(false);
}

// Declare an interrupt handler for the RTC_PIT interrupt
#[avr_device::interrupt(attiny1616)]
unsafe fn RTC_PIT() {
    handle_tick()
}

#[inline(always)]
pub unsafe fn handle_tick() {
    let (should_process, ticks_elapsed) = avr_device::interrupt::free(|t| {
        // increment the global ticks counter
        let elapsed = TICKS_ELAPSED.borrow(t).get() + 1;
        TICKS_ELAPSED.borrow(t).set(elapsed);

        // ensure we're not already processing the queue
        (mark_in_progress(t), elapsed)
    });

    if should_process {
        wake_queue::process(ticks_elapsed);
    }

    avr_device::interrupt::free(|t| {
        if should_process {
            mark_finished(t);
        }
        let mut state = INTERRUPT_STATE.borrow(t).borrow_mut();
        // clear the interrupt flag
        state.as_mut().unwrap().counter.clear_interrupt();
    });
}

/// Configure the RTC with the PIT enabled, firing at a rate of 1024Hz
pub fn init_system_time(tc: RTC) {
    unsafe {
        avr_device::interrupt::enable();
        avr_device::interrupt::free(|t| {
            TICKS_ELAPSED.borrow(t).set(0);

            let pitconfig = PitConfig::new(1, RTCClockSource::OSCULP32K_32K, PERIOD_A::CYC32);

            let mut pit = Pit::from_rtc(tc, pitconfig.clock_source, pitconfig.period);
            pit.enable_interrupt();
            pit.start();

            *INTERRUPT_STATE.borrow(t).borrow_mut() = Some(InterruptState {
                counter: pit,
            });
        });
    }
}
```

We're almost done, the last thing to do is tell Embassy how to read what the current time is:

```rust
impl Driver for AvrTc0EmbassyTimeDriver {
    #[inline(always)]
    fn now(&self) -> Time {
        avr_hal_generic::avr_device::interrupt::free(|cs|
            TICKS_ELAPSED.borrow(cs).get()
        );
    }

    // ... there's some more stuff here but it's unimportant
}
```

And with that, we can now use Embassy:

```rust
#[embassy_executor::task]
async fn blink(pin: atxtiny_hal::gpio::PA7<Input>) {
    let mut pin = pin.into_push_pull_output();
    loop {
        pin.toggle();

        embassy_time::Timer::after_millis(500).await;
    }
}
```

== Async peripheral drivers <async-peripheral-drivers>

With timers out of the way we can now look into implementing peripheral drivers
that are async compatible. Microcontrollers are already all setup for this as
it's common for peripherals to fire interrupts when its state changes, so we can
simply just hook up an interrupt handler to wake up tasks waiting on the
peripheral.

As an example, for GPIO pins it is common to want to wait until the state of an
input pin changes in some way, such as low to high, or high to low. On AVR you
may configure the microcontroller to fire an interrupt when such a state
transition happens.

This means we can easily build a Rust future which configures pin interrupts for
a pin, and then registers a waker such that when an interrupt is fired for the
pin, the task is woken back up.

To implement this for AVR I started with declaring a place to store a waker for
each pin:

```rust
// GPIO pins on AVR are grouped into 'ports'
const PORTA_PIN_COUNT: usize = 8;
const PORTB_PIN_COUNT: usize = 8;
const PORTC_PIN_COUNT: usize = 6;

// AtomicWaker is effectively just `Mutex<Cell<Option<Waker>>>`
static WAKERS: [AtomicWaker; PORTA_PIN_COUNT + PORTB_PIN_COUNT + PORTC_PIN_COUNT] =
    [const { AtomicWaker::new() }; PORTA_PIN_COUNT + PORTB_PIN_COUNT + PORTC_PIN_COUNT];


fn get_waker(port: u8, pin: u8) -> &'static AtomicWaker {
    &WAKERS[(port * PORTA_PIN_COUNT as u8 + pin) as usize]
    // omitting the bounds check saves only 8 bytes, it'd be ideal if it could
    // be elided.
    //
    // unsafe { WAKERS.get_unchecked((port * PORTA_PIN_COUNT as u8 + pin) as usize) }
}
```

Then we can declare the interrupt handlers for the pin interrupts, which will
wake up any wakers for pins that have an interrupt pending.

```rust
// To reduce code size, the true handler for pin interrupts is this function,
// which is passed the port for which the interrupt was served and wakes up
// any wakers for pins which have a pending interrupt.
fn int_handler(gpio: &dyn GpioInt, port: u8, pin_count: u8) {
    for i in 0..pin_count {
        if gpio.is_pending(i) {
            get_waker(port, i).wake();

            // clear and disable the interrupt, disabling the interrupt
            // is used to signal that the pin was woken.
            gpio.clear(i);
        }
    }
}

// Pin interrupts on AVR are grouped to the port the pin belongs to, the
// pin has a 'pending interrupt' flag which is used to check which pin(s)
// the interrupt was fired for.
#[avr_device::interrupt(attiny1616)]
unsafe fn PORTA_PORT() {
    int_handler(&*PORTA::PTR as &dyn GpioInt, 0, PORTA_PIN_COUNT as u8);
}

#[avr_device::interrupt(attiny1616)]
unsafe fn PORTB_PORT() {
    int_handler(&*PORTB::PTR as &dyn GpioInt, 1, PORTB_PIN_COUNT as u8);
}

#[avr_device::interrupt(attiny1616)]
unsafe fn PORTC_PORT() {
    int_handler(&*PORTC::PTR as &dyn GpioInt, 2, PORTC_PIN_COUNT as u8);
}

// Helper trait used for its vtable, this seems to have the least
// code size impact.
trait GpioInt {
    fn is_pending(&self, n: u8) -> bool;
    fn clear(&self, n: u8);
}

impl<T: GpioRegExt> GpioInt for T {
    fn is_pending(&self, n: u8) -> bool {
        // we need this proxy method as GpioRegExt isn't object safe
        self.interrupt_pending(n)
    }

    fn clear(&self, n: u8) {
        // enabling input buffering disables the interrupt
        self.enable_input_buffer(n);
        self.clear_interrupt_pending(n);
    }
}
```

Then on the other side we just need to create a Future which configures the
interrupt and registers the waker:

```rust
struct InputFuture<'d, Gpio, Index> {
    // A 'PeripheralRef' to the pin this future is for, this is a
    // Zero Sized Type that represents `&'d Pin<...>`
    pin: PeripheralRef<'d, Pin<Gpio, Index, Input>>,
}

impl<'d, Gpio: atxtiny_hal::gpio::marker::Gpio, Index: atxtiny_hal::gpio::marker::Index>
    InputFuture<'d, Gpio, Index>
{
    // configure the interrupt when we create the future
    fn new(mut pin: PeripheralRef<'d, Pin<Gpio, Index, Input>>, edge: Edge) -> Self {
        // clear the interrupt first in case the previous future was dropped
        pin.0.clear_interrupt();

        pin.0.configure_interrupt(edge);

        Self { pin }
    }
}

impl<'d, Gpio: atxtiny_hal::gpio::marker::Gpio, Index: atxtiny_hal::gpio::marker::Index> Future
    for InputFuture<'d, Gpio, Index>
{
    type Output = ();

    fn poll(
        self: core::pin::Pin<&mut Self>,
        cx: &mut core::task::Context<'_>,
    ) -> core::task::Poll<Self::Output> {
        let pin_idx = self.pin.0.pin_index();
        let waker = get_waker(self.pin.0.port_index(), pin_idx);

        waker.register(cx.waker());

        // creating the future enabled the interrupt, if it is disabled
        // then we know the interrupt handler fired for this pin and
        // disabled the interrupt on it.
        if !self.pin.0.is_interrupt_enabled() {
            return Poll::Ready(());
        }

        Poll::Pending
    }
}


impl<Gpio: atxtiny_hal::gpio::marker::Gpio, Index: atxtiny_hal::gpio::marker::Index>
    Pin<Gpio, Index, Input>
{
    pub fn wait(&mut self, edge: Edge) -> impl Future<Output = ()> + '_ {
        InputFuture::new(self.into_ref(), edge)
    }

    pub fn wait_high(&mut self) -> impl Future<Output = ()> + '_ {
        self.wait(Edge::Rising)
    }

    pub fn wait_low(&mut self) -> impl Future<Output = ()> + '_ {
        self.wait(Edge::Falling)
    }
}
```

Now we can write a function which waits for a button press, and then lights up a
LED for one second after:

```rust
#[embassy_executor::task]
async fn respond(led: atxtiny_hal::gpio::PA7<Input>, button: atxtiny_hal::gpio::PC3<Input>) {
    let mut button = crate::gpio::Pin::new(button.into_floating_input());
    loop {
        led.set_low();

        // wait for the button to be pressed
        t.wait(Edge::Falling).await;

        led.set_low();

        embassy_time::Timer::after_secs(1).await;
    }
}
```

This same technique can then be used to create an async driver for the ADC,
which fires an interrupt when the result is ready to be retrieved.

== Splitting up tasks <splitting-up-tasks>

Initially I expected to not actually use that many async tasks for this
flashlight firmware, but as it turns out, there's actually quite a few
concurrent processes you can decompse a flashlight into:

+ Debouncing the power button

  We want to do things when the power button is pressed and depressed, but due
  to the realities of the world we cannot just wait for highs and lows on the
  pin connected to the button as the signal will actually very quickly flip
  between low and high when the button is pressed and depressed. And so we need
  to perform debouncing of the button.

  We can model this incredibly simply as a single process: When we first see
  the button is pressed we can wait a period of time (16ms), and if the button
  is still pressed we then treat it as a press. We can act likewise for
  depresses.

  ```rust
  #[embassy_executor::task]
  pub async fn debouncer(t: atxtiny_hal::gpio::PC3<Input>) {
      let mut t = crate::gpio::Pin::new(t.into_floating_input());
      let mut l = unsafe {
          atxtiny_hal::avr_device::attiny1616::PORTC::steal()
              .split()
              .pc1
              .into_push_pull_output()
      };

      loop {
          l.set_low().unwrap_infallible();

          // wait for a pin event on the button pin (either a press, or bouncing)
          t.wait(Edge::Falling).await;
          let v = t.pin().is_low().unwrap_infallible();

          // if the button isn't pressed, abort
          if !v {
              continue;
          }

          embassy_time::Timer::after_millis(16).await;

          // if the button is still pressed after 16ms, consider it debounced and pressed
          if t.pin().is_low().unwrap_infallible() {
              BUTTON_STATES.signal(ButtonState::Press);
              LOCKOUT_BUTTON_STATES.signal(ButtonState::Press);
          } else {
              continue;
          }
          l.set_high().unwrap_infallible();

          // once pressed, we poll the button for depresses since sometimes the
          // edge interrupt can be missed
          loop {
              embassy_time::Timer::after_millis(16).await;
              // if the button is still pressed, do nothing
              if t.pin().is_low().unwrap_infallible() {
                  continue;
              }

              embassy_time::Timer::after_millis(16).await;

              // if the button has been depressed for two cycles, consider it
              // debounced and depressed
              if t.pin().is_high().unwrap_infallible() {
                  BUTTON_STATES.signal(ButtonState::Depress);
                  LOCKOUT_BUTTON_STATES.signal(ButtonState::Depress);
                  break;
              }
          }
      }
  }
  ```

+ Recognising button clicks and holds

  The UI of Andúril is structured around sequences of clicks that are
  optionally finished by a hold (long presses). For example: when the torch is
  unlocked, 1C (a single click) will turn on the light at the previously used
  brightness, while 1H (a single hold) will turn the light on at a default
  'low' brightness level. 4C (three clicks in a row) while the torch is locked
  will unlock it, and likewise when the torch is unlocked.

  I implemented recognising sequences of clicks and holds with a simple state
  machine that receives press and depress events from the debouncer process.
  After receiving a press event we wait for either a depress or a timeout of
  300ms. If a timeout occured we emit a hold event and proceed to wait for an
  eventual depress, however if a depress occured we count the click and proceed
  to wait for another 300ms in case the button is pressed again (in which case
  we return to see if that is a click or a hold), if nothing is pressed within
  the timeout we can emit a click event containg the count of clicks so far.

  Implemented in code, this looks like this:

  ```rust
  // This isn't the tidiest as we're intentionally encoding the state machine as data rather than code
  // as to reduce the number of await points.
  #[embassy_executor::task]
  pub async fn event_generator() {
      let mut state = EventGenState::FirstClick;
      loop {
          let (wait_until, expecting) = match state {
              EventGenState::FirstClick => (None, ButtonState::Press),
              EventGenState::ForHigh { .. } => (Some(Duration::from_millis(300)), ButtonState::Press),
              EventGenState::ForLow { .. } => {
                  (Some(Duration::from_millis(300)), ButtonState::Depress)
              }
              EventGenState::HoldFinish => (None, ButtonState::Depress),
          };

          let r = crate::with_timeout::with_timeout(wait_until, BUTTON_STATES.wait()).await;

          // r: true if pressed, false if held
          let r = match r {
              Ok(state) if state == expecting => true,
              Ok(_) => {
                  state = EventGenState::FirstClick;
                  continue;
              }
              Err(_) => false,
          };

          let (state_, evt) = match state {
              EventGenState::FirstClick => (EventGenState::ForLow { clicks: 1 }, None),
              EventGenState::ForHigh { clicks } => {
                  if r {
                      (EventGenState::ForLow { clicks: clicks + 1 }, None)
                  } else {
                      (
                          EventGenState::FirstClick,
                          Some(ButtonEvent::click_from_count(clicks)),
                      )
                  }
              }
              EventGenState::ForLow { clicks } => {
                  if r {
                      (EventGenState::ForHigh { clicks }, None)
                  } else {
                      (
                          EventGenState::HoldFinish,
                          Some(ButtonEvent::hold_from_count(clicks)),
                      )
                  }
              }
              EventGenState::HoldFinish => (EventGenState::FirstClick, Some(ButtonEvent::HoldEnd)),
          };
          state = state_;
          if let Some(evt) = evt {
              BUTTON_EVENTS.signal(evt);
          }
      }
  }
  ```

+ Controlling the AUX lights

- PWM and low aux modes

+ Monitoring temperature and battery voltage

- Also the watchdog

+ Controlling output brightness

- Reducing brightness to limit temperature
- Smoothly interpolating between levels

== Fighting the inliner, testing different representations, compiler flags and turbowakers <fighting-the-inliner-testing-different-representations-compiler-flags-and-turbowakers>

Pins need to be modelled at the type level so that we can verify pin
compatability statically, but once a pin is used by a peripheral, we can either
keep it generic or turn it into a runtime integer representing the pin number,
which can result in different code sizes.

== Async state machine code sizes, coalescing future helpers to reduce code size. <async-state-machine-code-sizes-coalescing-future-helpers-to-reduce-code-size>

== Running out of flash <running-out-of-flash>

- STM32 is the solution, but would require a custom driver design. Time to learn how a current controlled boost converter works.
- Designed a simple MP3432 boost driver using an stm32 to control it.

  - went with STM32L072KB, needs only some bypass caps and a LDO to provide a constant voltage, doesn't require an external oscillator. This chip has plenty of timers, flash, DACs, and ADCs.


== Ported codebase to stm32 <ported-codebase-to-stm32>

Didn't require much work as the UI and power control logic was already fairly generic.

Also tried out maitake and designed a new driver

\[^rusty-keyboards\]: #link("@/writing-keyboard-firmware-in-rust.md")[Writing keyboard firmware in rust]

\[^stackful\_tasks\]: By this I mean a runtime system that swaps out thread stacks

