/// Unicode emoji: rendered by the platform, not copied from another app.
const chatEmojiGroups = <String, String>{
  '笑脸':
      '😀 😃 😄 😁 😆 😅 😂 🤣 😊 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥳 🤩 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🫣 🤭 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😮‍💨 😵 😵‍💫 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 🤑 🤠 😇 🥸 🫠 🫡 🫢 🫤 🥹',
  '手势':
      '🙏 👍 👎 👏 🙌 👐 🤲 🤝 ✌️ 🤞 🤟 🤘 👌 🤌 🤏 👈 👉 👆 👇 ☝️ ✋ 🤚 🖐️ 🖖 👋 🤙 💪 🦾 ✍️ 🫶 👊 ✊ 🤛 🤜 🙏🏻 🙏🏼 🙏🏽 🙏🏾 🙏🏿 🙇 🙇‍♀️ 🙇‍♂️ 🧘 🧘‍♀️ 🧘‍♂️',
  '祝福':
      '❤️ 🧡 💛 💚 💙 💜 🤎 🖤 🤍 💗 💓 💕 💞 💖 💘 💝 💟 ❣️ 💔 ❤️‍🩹 ❤️‍🔥 🪷 🌸 🌼 🌻 🌹 🌺 🌷 💐 🕯️ 🪔 ☀️ 🌙 ⭐ 🌟 ✨ 🌈 🎉 🎊 🎁 🎂 🎈 🧧 🏮 🎆 🎇 🧨 🀄 🕊️ 🍀 🌱 🌿 🪴 🌳 🌲 🌴 🏵️ 🥀 🌾',
  '生活':
      '🐱 😺 😸 😹 😻 😽 🙀 😿 😾 🐶 🐼 🐻 🐨 🐯 🦁 🐮 🐷 🐵 🙈 🙉 🙊 🐰 🦊 🐸 🐧 🐦 🦋 🐝 🐢 🐘 🦌 🐎 🐬 🐟 🐳 🍎 🍊 🍋 🍉 🍇 🍓 🍒 🍑 🥭 🍍 🥝 🍐 🍌 🍚 🍜 🥟 🥬 🥕 🥦 🥒 🍵 ☕ 🥛 🥤 🍰 🍪 🍞 🥜 🌰 📚 📖 📝 ✏️ 🎵 🎶 🎧 🔔 ⏰ 📷 🏠 🏔️ 🛕 🌏 ✅ ❌ ❓ ❗ 💯 🔥 💧 💡',
};
const chatEmojiGroupEnglish = ['Faces', 'Gestures', 'Blessings', 'Daily life'];
final chatEmojiSet = chatEmojiGroups.values.expand((s) => s.split(' ')).toSet();
