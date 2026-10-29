# Using Threadbear

Threadbear is a Mac app for running AI agent threads. It drives the official
Claude Code and Codex command line tools on your own logins. A small program
called the runner keeps every agent going in the background, so quitting or
updating the app never stops a thread. Your threads are also copied to a
Convex deployment of your own, which is how the iPhone app and the website
can follow along.

This guide is for using it. `INSTALL.md` covers setting it up, and `docs/`
has how it all works inside.

## Threads

A thread is one conversation with an agent, working in one folder on your
Mac. You say what you want done, the agent does it (reading files, running
commands, making changes) and replies. You can have as many threads going as
you like, and each one remembers its whole conversation, so you can come
back to it days later and carry on.

## Full access or Ask before edits

Read this before your first thread. Every thread runs in one of two modes,
shown on the composer (the box you type in) and changed by clicking it.

- **Full access** (the default): the agent edits files and runs commands
  without asking. It can do anything your Mac user account can do, in any
  folder, including deleting files. This is how Threadbear is meant to be
  used day to day, and it's fine for a folder you trust it with.
- **Ask before edits**: the agent stops for your OK before it edits a file
  or runs a command. A card shows in the thread with Allow, Always allow and
  Deny. Always allow only lasts for that thread. A Codex thread in this mode
  can read files but not change them unless you agree.

The mode belongs to one thread. A new thread starts on Full access again
unless you pick otherwise, so if you're unsure about a task, switch it to Ask
before edits before you send. Deleting a thread is one thing an agent always
has to ask about, whatever the mode.

## Your first thread

Press ⌘N, or click New thread, type a message and press Return.

New threads start in the `Threadbear` folder in your home folder
(`~/Threadbear`), which setup makes for you. You can pick another folder for
one thread from the composer's + menu, or change the default in Settings
(⌘,).

A safe first message is one that only reads, such as "What's in this
folder?" or "Explain what you can do for me here." When you're ready for it
to make something, try "Make a file called hello.txt that says hi" and watch
it appear in `~/Threadbear`.

Return sends and Shift-Return adds a new line. In a list, Shift-Return
starts the next item ("2. " after "1. milk", "- " after "- milk"), and
Shift-Return on an empty item ends the list. You can paste or drop images
into the composer. Stop (⌘.) ends a turn that's running.

A message shows in the thread as soon as you send it, faded, with a
spinner beside it until the runner has it (a busy Mac can hold the runner
up for a few seconds). A clock instead means it's waiting for the turn
that's running to finish, and it starts its own turn then. If it can't be
sent, it goes and its text is back in the composer. Starting a new thread
keeps your message in the composer, greyed, with a spinner in place of
Send, until the thread exists.

### Going back to an earlier message

Hover over one of your own messages and click the pencil to change it. Its
text goes into the composer; send it and the thread goes back to that
point. The agent forgets that message and everything after it, the
changes it made to files since then are put back, and your new version is
sent as if the rest had never happened. A turn that's running is stopped
first. What was cut is gone from the thread, and a line where it was says
how many files were put back.

Files changed by commands the agent ran (a script, `git`, `npm install`)
aren't put back, only ones it edited or wrote itself. If you've changed one
of its files yourself since, that file may be left as it is, and the line
says so. A message you sent while the agent was working went into that
turn, so edit the message that started it instead.

## What the list tells you

The threads view has three sections. Inbox holds the threads for you, with
the ones that need you at the top. The number on the Threads icon in the
left-hand rail is how many are in it. The arrows at the end of its heading
sort it newest first or oldest first instead, which is handy for working
through a long inbox from the bottom up. Running holds threads whose agent is
working now. Waiting holds threads that have booked a message to themselves
for later (an agent saying "I'll check again in 20 minutes") and have nothing
for you until then: each says when it wakes, soonest first. When the time
comes it runs again, and lands in the inbox when it's done. A thread that
asks you something keeps its place in the inbox, wake-up or not.

At the right of each row:

- **Working**, with a spinner and a timer: the agent is busy.
- **Needs you**, in orange: the agent has asked you something, wants your OK,
  or has finished and said there's something for you to do.
- A blue dot before the title: a reply you haven't read yet.
- A time: the thread is idle. It finished and doesn't need anything: its
  last reply ends with a "Nothing needed from you" card, with an Archive
  thread button to put it away. After a while Threadbear stops its agent to save memory, and your next message
  starts it again where it left off.
- **Failed**: the last turn ended with an error. Read the thread to see why,
  and send a message to try again.
- **Stopped**: the runner restarted while the thread was busy.
- **Waiting for room**: every login it could use has hit its limit (see
  Accounts below). It carries on by itself when one has room again.

When an agent finishes a piece of work, its reply is a few short bullets
of what it did, with what it needs from you (or "Nothing needed from you")
under them. What it wrote while it worked is folded into the line of work
above, with its commands and edits. A link with ↑ after it goes to the
step it's about: click it and the work opens there, with that step lit
up. A link to another thread opens that thread.

Inside a thread, rest the pointer on a link for a moment, in a reply or on a
Needs you card's buttons, to see where it goes: a picture of the file, or
the page's address. Click it to open it.

## Schedules

A schedule sends a message at a set time, once or over and over: to a
thread, or to a new thread each time (a morning summary, say). Make one in
the Scheduled view, or ask an agent ("look at this again every weekday at
9"). The Scheduled view lists them with when each runs next.

If you run Threadbear on more than one Mac, a schedule that starts a new
thread can run on any of them: pick the Mac under Runs on. It runs there
even while this one is asleep, in that Mac's folder (leave the folder
empty for its default). Its threads show on your phone and the website;
the Mac app only shows this Mac's threads for now. Schedules need your
Convex backend: with no internet, they wait.



To put a thread away for a while, hibernate it (the Thread menu, the ...
menu, or the button that shows when you hover a row). Pick when it should
come back: in an hour, this evening, tomorrow, next Monday or a time of your
own. It leaves the list, its agent stops, and it comes back marked unread
when the time comes. Hibernating threads have their own view (⌘2).

Or pick Wake when… and say it in your own words: "at the weekend", "in a
few weeks", "next time I talk about woodworking". Opus works out what you
meant (the row says Thinking… for a few seconds) and the thread says what
it settled on. A topic waits for you to bring it up: when the librarian
sees you talking about it in another thread, it wakes this one and says
where.

When a thread is done, archive it with ⌘E, or swipe its row left with two
fingers on the trackpad (or drag it left with the mouse) and let go once the space behind it turns blue (a
quick flick works too). However it's archived (⌘E, a button, or an agent
or your phone doing it), its row slides off the same way. The Archive view (⌘3) lists them with a search box,
and Unarchive, or the same swipe there, puts one back. The iPhone app and the
website call the archive the Den.

## Accounts, pools and Usage

Threadbear uses the Claude Code and Codex logins already on your Mac: the
Claude Code login in `~/.claude` and the Codex login in `~/.codex`. It never
reads their passwords or tokens. The account and model a thread runs on are
small menus on the composer. Whatever you picked last is what the next
thread starts on.

Logins are grouped into pools, one for Claude and one for Codex to begin
with (Settings > Pools). A thread in a pool runs on whichever login has the
most room. When the one it's on gets close to its limit, it moves to
another login in the pool with room, and carries on from where it was. When
none has room, the thread waits and carries on by itself once a limit
resets. With only one login, that means it waits for that login's limit to
reset.

Usage, near the bottom of the left-hand rail, shows how much room each login
has left before it hits its limits (for Claude, the 5-hour and weekly ones).
Threadbear learns these numbers from the threads it runs, so a login's bars
fill in once it has run something.

At the top it shows what you've spent: tokens today (and what a usual day
had spent by this time), in the last hour and over the last 7 days, with a
chart by the hour or by the day, each login in its own colour. Hover a bar
to see who spent what. The tokens are read from the Claude and Codex
transcripts on your Mac, so work done outside Threadbear counts too; the
first read takes a minute or so after the runner updates.

Below that, each pool is a card, with each login in it: what it's spent
today, and its 5-hour and weekly windows. The weekly one has a small chart
of the week so far, with your current pace dashed on to the reset. When a
window would run out before it resets at that pace, it says when in
orange. Hover a window for its rate.

## Connectors

Agents get services like Notion, Sentry and Cloudflare from your Connectors
gateway, and Gmail, Drive and the like from claude.ai's connectors on each
login. Now and then one needs signing in again.

The Connectors icon (the plug) near the bottom of the left-hand rail opens a
panel listing the gateway's services and whether each is signed in. A blue
dot on the icon means one is signed out: click Connect beside it, and its
sign-in page opens in your browser. A grey dot means something's off that
usually sorts itself out, such as the gateway not answering for a moment.
The arrow in the panel checks again, and the ⓘ says more. If the gateway
can't be reached at all, the panel says so.

When an agent runs into a service that needs signing in, it asks you in its
reply, with a button that opens the page to do it on. claude.ai's own
connectors are signed in on claude.ai (Settings > Connectors), on the login
the thread runs on.

## The prompts macOS shows you

- **Notifications.** The first time the app opens, macOS asks whether
  Threadbear may send notifications. Click Allow. The app then tells you
  when a thread needs you and you aren't looking at it.
- **Folder access.** When an agent reaches into a protected folder, such as
  Desktop, Documents, Downloads or Dropbox, macOS asks whether to allow it.
  Click Allow if you want agents working there, or Don't Allow if not. You
  can change your mind later in System Settings > Privacy & Security >
  Files and Folders. Starting threads in `~/Threadbear` keeps these prompts
  away until you choose a folder that needs them.

## Your phone and a browser

The Threadbear iPhone app shows your threads, lets you answer the ones that
need you, and sends you notifications. It pairs with your Mac by scanning a
QR code: on the Mac, Settings (⌘,) > Phone & browser > Show the code, then
scan it with the iPhone app. Keep the code to yourself: anyone who scans it
can run your agents. The same tab lists each paired phone and browser with
when it was paired and until when (90 days), and Revoke signs one out;
Settings > Unpair this phone on the iPhone forgets it from that side. The
terminal command setup used to print still works too:

    swift ios/scripts/pair-qr.swift --prod --url <your deployment URL>

Notifications reach your phone only while you're away from the Mac by
default. Threadbear counts you as at the Mac when the app is open and you've
used the keyboard or mouse in the last two minutes, and as away when the Mac
is asleep. On the iPhone, Settings > Notify me changes it to Always or Never.

Quick ask on the iPhone: press the Action button, say a question, and hear
the answer from your Agent Archive server, the way the old Quick Ask app
did. Set it up in the iPhone's Settings > Quick ask (the archive server's
address and a phone token from it; the phone needs Tailscale to reach it),
then set the Action button to the Shortcut called Quick ask. The waveform
button in the inbox does the same. Each quick ask is kept as a thread in your default folder, with
the question, the answer and a note that quick ask answered it. It shows
as done and already read. Write in it to carry on: the agent is told the
thread started as a quick ask and picks up from there.

Your threads also have a website, on your own Convex deployment. To sign a
browser in, Settings > Phone & browser > Open signed in opens it in your
browser (or run `npm run web:sign-in` from your Threadbear folder). Each
thread has its own link: Copy web link in a
thread's ... menu on the Mac, or the Copy link button on the website, gives
you one to paste anywhere you're signed in.

To let someone else read a thread, click the share button beside a
thread's ... menu and pick Anyone with the link, then Copy link. It's a
read-only page anybody can open, which follows the thread as it carries on:
the messages, one line per step and the pictures, but not tool output, the
folder or the cost. Only you stops the link working (sharing again brings
the same link back), and the arrows beside the link make a new one, which
stops the old. The same Share button is on the website, on your thread's
page and on the shared page while you're signed in.

The Mac app also draws a picture an agent writes into its reply with a path
on your Mac (`![a chart](/path/to/chart.png)`), rather than showing a link.

## Patches: your own buttons and panels

A patch adds buttons (chips above the composer) and panels (beside the
thread) for the threads in a folder. A button can run a command, like your
tests, or send the agent a message you use a lot. A panel can show a web
page, such as your app running on localhost, or a list.

Each panel has a button on the right-hand rail, with a small badge in its
bottom corner (and on the panel's tab) saying where it came from: the project's own icon when it came
from one of the thread's projects' folders, a folder for the thread's own
folder, a house for `~/.threadbear`, a wrench for a tool patch (one that's
there because of a file, like a video's `.tandem`) and a box for one built
into Threadbear. Hover over the button to see it in words.

You don't need to write one yourself. In a thread in that folder, ask
"add a button that runs the tests" or "add a panel showing localhost:3000",
and the agent writes the patch into the folder's `.threadbear/patches/`
(the format is under "Patches" in `docs/protocol.md`, in your Threadbear
folder). It shows up within a few seconds. A patch is code that runs on your
Mac, so keep only the ones you'd be happy to run.

A project's page has its own panels and Patches on the right-hand rail:
the ones its folders give its threads.

## Changing Threadbear itself

You can change Threadbear by asking a thread to. Start one in your
Threadbear folder (the clone setup ran from) and say what you'd like
different. A thread there gets its own copy of the code to work in, and when
the change is ready and its checks pass, the agent lands it on your `main`
branch.

Updates then arrive by themselves. Within a few minutes of a change landing
on `main`, the runner builds it and switches over without cutting off any
thread that's partway through a turn, and the app builds its new version in
the background. The app swaps in the new version when you next quit it, when
you choose Restart to Update in the Threadbear menu, or by itself when you've
left it alone for a while with nothing typed. The window stays where it is
while it does: the new version opens the same thread underneath and takes
over, so you shouldn't see it go.

The Updates icon on the left-hand rail shows what's on its way for the app,
the runner and the Claude Code and Codex tools. A grey dot means something
is in progress and will sort itself out, and a coloured dot means it needs
you. Right-click it for a quick Restart to Update.

## Privacy

Your threads are mirrored to a Convex deployment in your own Convex account,
which setup made: the thread list, the text of each message, and one line
for each thing an agent did. Tool output and images stay on your Mac.
A thread you share can be read by anyone with its link, pictures included,
and only that thread. The pictures are uploaded only while it's shared.
Notifications to your phone go through a small relay Mike runs, because
Apple only delivers notifications for his app through his key. The text is
locked with a key only your phone and your deployment have, so the relay
never sees what a notification says.

## Getting help

- Ask a thread. Its agent knows where this guide is and can read it, or
  look at the code and tell you how something works.
- Ask a thread to run `tb status`, which says what the runner is doing:
  its version, the threads that are busy, and any restart or update on the
  way.
- `threadbear` in Terminal opens the app, and quitting it with ⌘Q is always
  safe, since your threads keep running without it. If the app says it
  can't reach the runner, click Start runner.

## The tour and Finish setting up

The first time the app opens it shows you round the window, one part at a
time. Help > Take the Tour runs it again.

The tour ends on Finish setting up, a short list of what's left after
setup: start your first thread (which shows your login works), allow
notifications, pair your iPhone and open your website. Each item ticks
itself off once it's done, and its icon on the left goes when they all
have. Hide this list puts it away, and Help > Finish Setting Up brings it
back.
