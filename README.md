# Discord Language Mirror

A small macOS app that places translated text over visible messages in the Discord desktop client. It keeps the speaker, time, and reply context in Discord, and offers a side panel with original and translated text. Choose the source language (or a channel-name hint) and the target language independently.

**Status:** 0.5 beta. Built for Apple silicon and macOS 15 or newer. Tested locally with the Discord desktop client, Japanese-to-Simplified-Chinese messages, and switching the target to English. Other language pairs depend on Apple's Translation framework and may require a language download. Unsupported pairs are reported in the app.

## Install

Download [Discord Language Mirror 0.5 for macOS](https://github.com/Juliejue/discord-language-mirror/releases/download/v0.5.0/Discord-Language-Mirror-0.5-macOS-arm64.zip), unzip it, and move the app to Applications. The ZIP is ad-hoc signed, not Apple notarized, so macOS may ask you to explicitly open it from Finder. The first launch also needs **System Settings → Privacy & Security → Accessibility** permission for this app. macOS may ask to download a language pack the first time you choose a new pair.

1. Open the Discord desktop app and the channel you want to read.
2. Open Discord Language Mirror, choose source and target languages, then press **开始**.
3. Keep **覆盖原文** on for inline translation, or turn on **显示逐条对照** for a readable side list.

The app reads the Discord window through macOS Accessibility and uses Apple's Translation framework. It has no Discord bot, token, account login, server, telemetry, or message-sending feature. The current source does not write chat content to disk. Apple's translation models run on device; macOS downloads language data when needed. It works only on messages currently represented in Discord's visible UI, and does not read text inside images or every embedded card.

## Build from source

On Apple silicon macOS 15+ with Xcode Command Line Tools:

```sh
./build.sh
```

The app and ZIP appear in `dist/`. Each local build uses an ad-hoc signature. Replacing a previously authorized build can require removing its old Accessibility entry and granting the new build permission again.

## Scope and limitations

- The “follow channel” source option infers language from obvious channel names. Choose a source language manually when a channel mixes languages or has an unrelated name.
- Translation quality varies, especially for slang, names, and short messages. Keep original text visible when a nuance matters.
- Grouped Discord messages without a repeated speaker heading, reply previews, image text, and complex embeds may be missed.
- This is an independent tool and is not affiliated with Discord or Apple.

