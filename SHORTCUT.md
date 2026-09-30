# "It's Showtime" Shortcut

This iPhone Shortcut is what Siri runs when you say **"Hey Siri, it's showtime"**. It loops: listen → send to Lyra → speak the reply, until Lyra says the conversation is over.

You need the **Server URL** and **API token** printed by `local/start.sh` (laptop) or `deploy/setup.sh` (server).

## Option A: start from ClawPod's Shortcut (fastest)

1. On your iPhone, download [`Activate the Kraken.shortcut`](https://github.com/algal/clawpod/raw/main/Activate%20the%20Kraken.shortcut) from the ClawPod repo and open it to import it.
2. Rename it to **It's Showtime**.
3. Edit it:
   - **Text** action at the top: replace the URL with your Lyra server URL (e.g. `http://my-macbook.local:7001` on your laptop, or `https://203-0-113-7.sslip.io` on a server).
   - **Speak** action: change the greeting to e.g. `Lyra here.`
   - **Get Contents of URL** action: expand it. Under **Headers**, add `Authorization` = `Bearer <your API token>`. In the JSON body, set `speaker` to your name.
4. Do the privacy settings below.

## Option B: build it from scratch

Open **Shortcuts → +**, name it **It's Showtime**, and add these actions (search each by name):

```
Speak "Lyra here"
Text {}
Set Variable  last  to  Text
Repeat 50 times
   Get Value for  waiting  in  last
   If  Dictionary Value  has any value
      Text  __lyra_poll__
   Otherwise
      Ask for Text with "Go on?"
   End If
   Get contents of  https://<your-server>/chat
        Method POST · Header Authorization = Bearer <token>
        JSON body: text = If Result, speaker = <your name>
   Set Variable  last  to  Contents of URL
   Get Value for  reply  in  Contents of URL
   Speak  Dictionary Value
   Get Value for  end_conversation  in  Contents of URL
   If  Dictionary Value  has any value
      Stop This Shortcut
   Otherwise
   End If
End Repeat
```

How it works:
- Lyra answers each request within ~4 seconds, because Siri hangs up on slow hands-free requests after only a few seconds.
- If a task needs longer, Lyra says "On it, one moment" and includes `waiting` in its response. The next loop then **skips "Go on?"** and sends `__lyra_poll__`, so Lyra speaks the result (or a question like "What time?") as soon as it's ready, without you having to ask.
- `end_conversation` and `waiting` are only present when true; Shortcuts can't reliably compare JSON `true`, but "has any value" always works.

When Siri runs the Shortcut hands-free, "Ask for Input" becomes a spoken prompt and you answer by voice. When you tap it in the app, it shows a keyboard instead (tap the 🎤 on the keyboard to dictate).

## Privacy and Siri settings

- **Shortcut details (ⓘ) → Privacy:** enable **Allow Running When Locked**. When first asked, allow the Shortcut to access your server URL.
- **Settings → Siri:** enable **Listen for "Hey Siri"** (or "Siri or Hey Siri") and **Allow Siri When Locked**.
- **Settings → [your AirPods]:** make sure Siri is enabled for them.

## Test

1. Run the Shortcut by tapping it in the Shortcuts app. You'll get a text box; type `hello`.
2. Lock the phone, put your AirPods in, and say **"Hey Siri, it's showtime."**
3. Say **"goodbye"** to finish.

**If Siri opens something else** (the Showtime app, a song): rename the Shortcut to something more distinctive, like **Lyra Showtime**, and say that instead.

**Different family members:** each person installs the Shortcut on their own phone with their own `speaker` name, so each gets a separate conversation history.
