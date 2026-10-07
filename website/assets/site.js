/*
 * 语言切换。
 *
 * 初始值在页面 head 里的内联脚本中设置（CSS 之前，避免刷新时闪一下双语）；
 * 这里只负责「按钮点击 → 换语言」，并把选择记在本机，刷新后保持。
 *
 * 没有 JS 时：`html[data-lang]` 不存在，两种语言的块都会显示（CSS 里只有
 * 命中 `[data-lang=…]` 才隐藏对方），页面依然完整可读——这是刻意的降级。
 */
(function () {
  var KEY = 'mangatranslater.lang';
  var root = document.documentElement;

  try {
    var saved = window.localStorage.getItem(KEY);
    if (saved === 'en' || saved === 'zh-Hans') {
      root.dataset.lang = saved;
    }
  } catch (error) {
    // 隐私模式下 localStorage 可能不可用，忽略即可
  }

  function label() {
    root.lang = root.dataset.lang === 'zh-Hans' ? 'zh-Hans' : 'en';
  }

  var toggle = document.getElementById('lang-toggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      root.dataset.lang = root.dataset.lang === 'zh-Hans' ? 'en' : 'zh-Hans';
      try {
        window.localStorage.setItem(KEY, root.dataset.lang);
      } catch (error) {
        /* 同上 */
      }
      label();
    });
  }

  label();
})();
