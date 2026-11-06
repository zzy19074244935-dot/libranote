/* 兼容 polyfill：epub.js 用了 ES2024 的 Object.groupBy / Map.groupBy
   （Chrome 117+），老内核 WebView/WebView2 没有 → EPUB 打开报
   "TypeError: Object.groupBy is not a function"。host.html / reader.html
   在模块脚本前加载本文件（模块是 deferred，classic 脚本先执行）。 */
(function () {
  if (typeof Object.groupBy !== 'function') {
    Object.groupBy = function (items, callbackFn) {
      if (items == null) throw new TypeError('items is not iterable');
      var groups = Object.create(null);
      var i = 0;
      for (var _i = 0, _a = items; _i < _a.length; _i++) {
        var item = _a[_i];
        var key = callbackFn(item, i++);
        var list = groups[key];
        if (!list) { list = groups[key] = []; }
        list.push(item);
      }
      return groups;
    };
  }
  if (typeof Map.groupBy !== 'function') {
    Map.groupBy = function (items, callbackFn) {
      if (items == null) throw new TypeError('items is not iterable');
      var groups = new Map();
      var i = 0;
      for (var _i = 0, _a = items; _i < _a.length; _i++) {
        var item = _a[_i];
        var key = callbackFn(item, i++);
        var list = groups.get(key);
        if (!list) { list = []; groups.set(key, list); }
        list.push(item);
      }
      return groups;
    };
  }
})();
