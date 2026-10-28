import Foundation
import JavaScriptCore

/// One menu of the router web interface as the router's own `require/modules/menuTree.js` lists it, evaluated
/// against the router's own `state.js`: names in the router's interface language, tabs in web order, and whether
/// the web shows each one on this router.
public struct RouterMenuEntry: Sendable, Hashable, Codable {
    public enum TabKind: String, Sendable, Hashable, Codable {
        /// `__HIDE__`: the menu's own page, shown without a tab bar.
        case page
        /// A named tab.
        case tab
        /// `__INHERIT__`: reached from a link on another page of the menu.
        case subpage
    }
    public struct Tab: Sendable, Hashable, Codable {
        public let url: String
        public let name: String
        public let kind: TabKind
        public let visible: Bool
        public init(url: String, name: String, kind: TabKind, visible: Bool) {
            self.url = url; self.name = name; self.kind = kind; self.visible = visible
        }
    }
    /// menuTree.js `index`, e.g. "menu_Wireless"; `menu_Split` rows are the web's group headings.
    public let index: String
    public let name: String
    public let visible: Bool
    public let tabs: [Tab]
    /// The tab the web opens when the menu is clicked: the first one it does not exclude.
    public let entry: String?
    public init(index: String, name: String, visible: Bool, tabs: [Tab], entry: String?) {
        self.index = index; self.name = name; self.visible = visible; self.tabs = tabs; self.entry = entry
    }
    public var isGroupHeading: Bool { index == "menu_Split" }
}

/// Facts the router's own state.js computes for its pages, read after running it.
public struct RouterWebFacts: Sendable, Equatable, Codable {
    /// `based_modelid`, the model the web's checks use.
    public var model: String?
    /// `odmpid`, the marketed model name when it differs.
    public var marketedModel: String?
    /// `ui_lang`, e.g. "CN" or "EN".
    public var language: String?
    /// The band of each radio unit as the web names it (`wl_nband_title`), e.g. ["2.4 GHz", "5 GHz"].
    public var bandTitles: [String]?
    /// `wlnband_list`, e.g. ["2g1", "5g1", "6g1"].
    public var bandList: [String]?
    /// The `ui_support` capabilities, as isSupport() reads them.
    public var uiSupport: [String: Double]
    public init(model: String? = nil, marketedModel: String? = nil, language: String? = nil, bandTitles: [String]? = nil,
                bandList: [String]? = nil, uiSupport: [String: Double] = [:]) {
        self.model = model; self.marketedModel = marketedModel; self.language = language
        self.bandTitles = bandTitles; self.bandList = bandList; self.uiSupport = uiSupport
    }
    public func supports(_ capability: String) -> Bool { (uiSupport[capability] ?? 0) != 0 }
}

/// Evaluates the router's menu the way its web interface does (state.js `showMenuTree`): the router's own state.js
/// runs first, so every `*_support` flag and nvram value it computes is the router's own; then menuTree.js, whose
/// `exclude.menus()` and `exclude.tabs()` decide what the web hides.
///
/// The scripts run in a bare JavaScriptCore context: no DOM, network, timers or file access. Browser objects are a
/// single inert stand-in that accepts every call and reads as an empty string, so `document.write` and cookie
/// reads at the top of state.js do nothing. A global the exclusion functions read but this firmware never defines
/// counts as unsupported (0), as an undefined `*_support` does in the web.
///
/// The app runs them in a child process of its own executable (`childArgument`, BoundedProcess): one that loops
/// or allocates without end is killed at the time, output or memory limit, and nothing of it stays in the app.
public enum RouterMenuEvaluator {
    public struct Result: Sendable, Equatable, Codable {
        public let menus: [RouterMenuEntry]
        public let facts: RouterWebFacts
        /// What did not run cleanly but did not stop the evaluation, for diagnostics.
        public let notes: [String]
    }
    public enum Failure: Error, Equatable, Codable, LocalizedError {
        case tooLarge
        case script(String)
        case shape(String)
        case timeout
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "路由器的菜单脚本超出大小限制。"
            case .script(let message): "路由器的菜单脚本无法求值：\(message)"
            case .shape(let what): "路由器的菜单脚本格式不同（\(what)）。"
            case .timeout: "路由器的菜单脚本求值超时。"
            }
        }
    }

    /// The argument that makes the app's executable serve one evaluation (`serveChild`) instead of starting the app.
    public static let childArgument = "--evaluate-router-menu"
    static let sizeLimit = 2_000_000
    /// What the child may answer and use: a real router's menu is some 40 KB of JSON in a process of some 40 MB.
    static let replyLimit = 1_000_000
    static let memoryLimit: UInt64 = 512 << 20
    static let maxMenus = 128, maxTabs = 64, maxText = 160, maxURL = 256, maxCapabilities = 2_000
    /// Undefined globals defaulted to 0, each in a fresh context.
    static let maxDefaulted = 24

    struct Request: Codable { let state: String; let menuTree: String }
    struct Reply: Codable { var result: Result?; var failure: Failure? }

    /// Evaluates in a child process: `helper` started with `arguments` (the app's own executable with
    /// `childArgument`), killed past `timeout`, `replyLimit` bytes of output or `memoryLimit` of memory.
    public static func evaluate(state: String, menuTree: String, helper: URL, arguments: [String] = [childArgument],
                                timeout: TimeInterval = 4) async throws -> Result {
        guard state.utf8.count <= sizeLimit, menuTree.utf8.count <= sizeLimit else { throw Failure.tooLarge }
        let request = try JSONEncoder().encode(Request(state: state, menuTree: menuTree))
        let output: Data
        do {
            output = try await BoundedProcess.run(executable: helper, arguments: arguments, input: request,
                                                  limits: .init(timeout: timeout, outputLimit: replyLimit, memoryLimit: memoryLimit))
        } catch let failure as BoundedProcess.Failure {
            switch failure {
            case .timeout: throw Failure.timeout
            case .outputTooLarge, .memory: throw Failure.tooLarge
            case .cancelled: throw CancellationError()
            case .launch(let message): throw Failure.script("无法启动求值进程（\(message)）")
            // 5: the child's own memory watch (serveChild).
            case .exit(let status): throw status == 5 ? Failure.tooLarge : Failure.script("求值进程异常退出（\(status)）")
            // RLIMIT_CPU (serveChild) ends a script that keeps the processor busy.
            case .signal(let signal): throw signal == SIGXCPU ? Failure.timeout : Failure.script("求值进程被终止（信号 \(signal)）")
            }
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: output) } catch { throw Failure.shape("求值结果") }
        if let failure = reply.failure { throw failure }
        guard let result = reply.result else { throw Failure.shape("求值结果") }
        return try result.checked()
    }

    /// The child's side: one request on standard input, one reply on standard output. Returns the exit status.
    public static func serveChild() -> Int32 {
        // The parent's limits stop it anyway; these keep a runaway child from outliving a parent that died: the
        // processor time limit, and a watch of its own that ends it when the app is gone or its memory passes the limit.
        var cpu = rlimit(rlim_cur: 8, rlim_max: 9)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        var core = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &core)
        let parent = getppid()
        Thread.detachNewThread {
            while true {
                if getppid() != parent { _exit(4) }
                if let used = BoundedProcess.footprint(of: getpid()), used > memoryLimit { _exit(5) }
                usleep(25_000)
            }
        }
        var input = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
            input.append(chunk)
            if input.count > 3 * sizeLimit { return 2 }
        }
        do { try FileHandle.standardOutput.write(contentsOf: serve(input)) } catch { return 3 }
        return 0
    }

    static func serve(_ input: Data) -> Data {
        var reply = Reply()
        do {
            let request = try JSONDecoder().decode(Request.self, from: input)
            reply.result = try run(state: request.state, menuTree: request.menuTree)
        } catch let failure as Failure {
            reply.failure = failure
        } catch {
            reply.failure = .shape("求值请求")
        }
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        guard data.count <= replyLimit else { return (try? JSONEncoder().encode(Reply(result: nil, failure: .tooLarge))) ?? Data() }
        return data
    }

    /// Evaluates in this thread. A global the exclusion functions read but this firmware never defines starts a fresh
    /// evaluation with it set to 0, so exclusion functions that change the menu list before they fail run once.
    static func run(state: String, menuTree: String) throws -> Result {
        guard state.utf8.count <= sizeLimit, menuTree.utf8.count <= sizeLimit else { throw Failure.tooLarge }
        var defaulted: [String] = []
        for _ in 0...maxDefaulted {
            switch try attempt(state: state, menuTree: menuTree, defaulted: defaulted) {
            case .done(let result): return result
            case .missing(let name):
                guard !defaulted.contains(name) else { throw Failure.script("Can't find variable: \(name)") }
                defaulted.append(name)
            }
        }
        throw Failure.script("未定义的全局变量过多")
    }

    private enum Attempt { case done(Result), missing(String) }

    private static func attempt(state: String, menuTree: String, defaulted: [String]) throws -> Attempt {
        guard let context = JSContext() else { throw Failure.script("JavaScriptCore") }
        let errors = ErrorLog()
        context.exceptionHandler = { _, value in errors.add(value?.toString() ?? "错误") }
        context.evaluateScript(prelude)
        if let first = errors.take().first { throw Failure.script("prelude: \(first)") }
        context.evaluateScript(state)
        var notes = errors.take().prefix(3).map { "state.js: \(String($0.prefix(maxText)))" }
        // Only names missingVariable(in:) accepted: identifiers, never code.
        if !defaulted.isEmpty { context.evaluateScript(defaulted.map { "var \($0) = 0;" }.joined(separator: " ")) }
        context.evaluateScript(defineShim)
        context.evaluateScript(menuTree)
        if let first = errors.take().first {
            if let name = missingVariable(in: first) { return .missing(name) }
            throw Failure.script(String(first.prefix(maxText)))
        }
        guard context.evaluateScript(shapeCheck)?.toBool() == true else { throw Failure.shape("menuTree.list / exclude") }

        let value = context.evaluateScript(extract)
        let thrown = errors.take()
        guard thrown.isEmpty, let value, value.isString, let json = value.toString() else {
            if let message = thrown.first, let name = missingVariable(in: message) { return .missing(name) }
            if let message = thrown.first, message.contains("RouterBar: too large") { throw Failure.tooLarge }
            throw Failure.script(String((thrown.first ?? "菜单").prefix(maxText)))
        }
        guard json.utf8.count <= replyLimit / 2, let data = json.data(using: .utf8) else { throw Failure.tooLarge }
        if !defaulted.isEmpty { notes.append("未定义、按不支持处理：" + defaulted.joined(separator: ", ")) }
        let raw: [RawMenu]
        do { raw = try JSONDecoder().decode([RawMenu].self, from: data) } catch { throw Failure.shape("菜单列表") }
        guard !raw.isEmpty else { throw Failure.shape("菜单为空") }
        let menus = raw.map { menu in
            RouterMenuEntry(index: menu.index, name: String(plain(menu.name).prefix(maxText)), visible: menu.visible,
                            tabs: menu.tabs.map { .init(url: $0.url, name: String(plain($0.name).prefix(maxText)), kind: .init(rawValue: $0.kind) ?? .tab, visible: $0.visible) },
                            entry: menu.entry)
        }
        let facts = (context.evaluateScript(factsScript)?.toString()).flatMap { $0.utf8.count <= replyLimit / 4 ? $0.data(using: .utf8) : nil }
            .flatMap { try? JSONDecoder().decode(RouterWebFacts.self, from: $0) } ?? RouterWebFacts()
        return .done(try Result(menus: menus, facts: facts, notes: Array(notes)).checked())
    }

    /// The identifier in JavaScriptCore's "Can't find variable: name" message.
    static func missingVariable(in message: String) -> String? {
        guard let range = message.range(of: "Can't find variable: ") else { return nil }
        let name = String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]{0,63}$"#, options: .regularExpression) != nil ? name : nil
    }

    /// Menu names are inserted into the web's HTML as they are; keep their text.
    static func plain(_ html: String) -> String {
        let text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return HTMLText.decode(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RawMenu: Decodable {
        struct RawTab: Decodable { let url: String; let name: String; let kind: String; let visible: Bool }
        let index: String; let name: String; let visible: Bool; let tabs: [RawTab]; let entry: String?
    }

    private final class ErrorLog: @unchecked Sendable {
        private var messages: [String] = []
        func add(_ message: String) { messages.append(message) }
        func take() -> [String] { defer { messages.removeAll() }; return messages }
    }

    // MARK: Scripts

    /// One inert stand-in for every browser object: any property is the stand-in again, any call returns it,
    /// and it converts to an empty string.
    static let prelude = """
    var __stub = (function(){
      var handler = {
        get: function(target, property) {
          if (property === Symbol.toPrimitive || property === "toString" || property === "valueOf") return function(){ return ""; };
          if (property === "length") return 0;
          return __stub;
        },
        set: function(){ return true; },
        has: function(){ return false; },
        apply: function(){ return __stub; },
        construct: function(){ return __stub; },
        deleteProperty: function(){ return true; }
      };
      return new Proxy(function(){}, handler);
    })();
    var window = this, self = this, top = this, parent = this, frames = this;
    var document = __stub, navigator = __stub, location = __stub, history = __stub, screen = __stub, event = __stub;
    var localStorage = __stub, sessionStorage = __stub, XMLHttpRequest = __stub, Image = __stub;
    // state.js of 3.0.0.6 calls $.inArray while it loads (DUT_SUPPORT_WLBANDS); the rest of jQuery is not needed.
    var $ = new Proxy(function(){ return __stub; }, {
      get: function(target, property) {
        if (property === "inArray") return function(value, list){ return list && typeof list.indexOf === "function" ? list.indexOf(value) : -1; };
        return __stub[property];
      }
    });
    var jQuery = $;
    function setTimeout(){ return 0; } function setInterval(){ return 0; } function clearTimeout(){} function clearInterval(){}
    function alert(){} function confirm(){ return false; } function prompt(){ return null; }
    var console = { log: function(){}, warn: function(){}, error: function(){}, info: function(){}, debug: function(){} };
    """

    /// require.js `define`, with or without a dependency list; the module is the menu tree.
    static let defineShim = """
    var menuTree;
    function define(a, b){ var f = typeof a === "function" ? a : b; if (typeof f === "function") menuTree = f(); else if (a && typeof a === "object" && !Array.isArray(a)) menuTree = a; }
    """

    static let shapeCheck = """
    typeof menuTree === "object" && menuTree !== null && Array.isArray(menuTree.list) && typeof menuTree.exclude === "object"
      && typeof menuTree.exclude.menus === "function" && typeof menuTree.exclude.tabs === "function"
    """

    /// state.js `showMenuTree`: a menu shows when some tab is not excluded and the menu itself is not; it opens at
    /// that first tab, and a first tab of "NULL" hides it. Tabs named __HIDE__ or __INHERIT__ are pages without a tab.
    /// 3.0.0.6 keeps an excluded Modem tab in the USB application menu in router and WISP mode (getTabCode); older
    /// lines hide every excluded tab, so the rule applies only where the router's own showMenuTree has it.
    static let extract = """
    (function(){
      var tooLarge = function(){ throw new Error("RouterBar: too large"); };
      if (menuTree.list.length > \(maxMenus)) tooLarge();
      var ex = { menus: menuTree.exclude.menus(), tabs: menuTree.exclude.tabs() };
      var support = function(name){ try { return isSupport(name) ? 1 : 0; } catch (e) { return 0; } };
      var alexa = typeof alexa_support !== "undefined" ? alexa_support : support("alexa");
      var ifttt = typeof ifttt_support !== "undefined" ? ifttt_support : support("ifttt");
      var lang = typeof ui_lang !== "undefined" ? String(ui_lang) : "";
      var routerOrWISP = (function(){ try { return isSwMode("RT") || isSwMode("WISP"); } catch (e) { return true; } })();
      var modemRule = (function(){
        try { return typeof showMenuTree === "function" && String(showMenuTree).indexOf('indexOf("Advanced_Modem_Content") == -1') !== -1; }
        catch (e) { return false; }
      })();
      var out = [];
      for (var i = 0; i < menuTree.list.length; i++) {
        var menu = menuTree.list[i];
        var tabs = Array.isArray(menu.tab) ? menu.tab : [];
        if (tabs.length > \(maxTabs)) tooLarge();
        var first = -1;
        for (var j = 0; j < tabs.length; j++) { if (ex.tabs.indexOf(tabs[j].url) === -1) { first = j; break; } }
        var visible = first !== -1 && ex.menus.indexOf(menu.index) === -1;
        if (visible && menu.index !== "menu_Split" && tabs[first].url === "NULL") visible = false;
        if (visible && menu.index === "menu_QIS" && support("is_ax5400_i1")) visible = false;
        var name = String(menu.menuName).slice(0, \(4 * maxText));
        if (menu.index === "menu_Alexa_IFTTT" && (!alexa || !ifttt)) name = alexa ? "Amazon Alexa" : "IFTTT";
        else if (name === "AiMesh" && lang === "CN") name = "AiMesh 随心组网";
        var list = [];
        for (var k = 0; k < tabs.length; k++) {
          var tab = tabs[k];
          var url = String(tab.url);
          if (url === "NULL") continue;
          if (url.length > \(maxURL)) tooLarge();
          var kind = tab.tabName === "__HIDE__" ? "page" : tab.tabName === "__INHERIT__" ? "subpage" : "tab";
          var shown = ex.tabs.indexOf(tab.url) === -1;
          if (!shown && modemRule && kind === "tab" && url.indexOf("Advanced_Modem_Content") !== -1 && routerOrWISP && menu.index === "menu_APP") shown = true;
          list.push({ url: url, name: String(tab.tabName).slice(0, \(4 * maxText)), kind: kind, visible: shown });
        }
        var index = String(menu.index);
        if (index.length > \(maxText)) tooLarge();
        out.push({ index: index, name: name, visible: visible, tabs: list,
                   entry: first === -1 || tabs[first].url === "NULL" ? null : String(tabs[first].url) });
      }
      var json = JSON.stringify(out);
      if (json.length > \(replyLimit / 2)) tooLarge();
      return json;
    })()
    """

    static let factsScript = """
    (function(){
      var facts = {};
      try { if (typeof based_modelid !== "undefined") facts.model = String(based_modelid).slice(0, 64); } catch (e) {}
      try { if (typeof odmpid !== "undefined" && String(odmpid) !== "") facts.marketedModel = String(odmpid).slice(0, 64); } catch (e) {}
      try { if (typeof ui_lang !== "undefined") facts.language = String(ui_lang).slice(0, 16); } catch (e) {}
      var short = function(list, length){ return list.slice(0, 8).map(function(item){ return String(item).slice(0, length); }); };
      try { if (Array.isArray(wl_nband_title)) facts.bandTitles = short(wl_nband_title, 32); } catch (e) {}
      try { if (Array.isArray(wlnband_list)) facts.bandList = short(wlnband_list, 16); } catch (e) {}
      facts.uiSupport = {};
      try {
        var source = String(isSupport);
        var start = source.indexOf("ui_support");
        var open = start === -1 ? -1 : source.indexOf("{", start);
        if (open !== -1) {
          var depth = 0, end = -1;
          for (var i = open; i < source.length; i++) {
            var c = source.charAt(i);
            if (c === "{") depth++;
            else if (c === "}") { depth--; if (depth === 0) { end = i; break; } }
          }
          if (end !== -1) {
            var values = JSON.parse(source.substring(open, end + 1));
            var count = 0;
            for (var key in values) {
              if (++count > \(maxCapabilities)) break;
              var n = Number(values[key]);
              if (key.length <= 64 && !isNaN(n)) facts.uiSupport[key] = n;
            }
          }
        }
      } catch (e) {}
      if (Object.keys(facts.uiSupport).length === 0 && typeof ui_support === "object" && ui_support) {
        var count2 = 0;
        for (var key2 in ui_support) {
          if (++count2 > \(maxCapabilities)) break;
          var m = Number(ui_support[key2]);
          if (key2.length <= 64 && !isNaN(m)) facts.uiSupport[key2] = m;
        }
      }
      return JSON.stringify(facts);
    })()
    """
}

extension RouterMenuEvaluator.Result {
    /// The bounds a router's menu stays far within; past them it is not a menu, whatever produced it.
    func checked() throws -> Self {
        typealias Limit = RouterMenuEvaluator
        let menusFit = menus.count <= Limit.maxMenus && menus.allSatisfy { menu in
            menu.index.count <= Limit.maxText && menu.name.count <= Limit.maxText && (menu.entry?.count ?? 0) <= Limit.maxURL
                && menu.tabs.count <= Limit.maxTabs && menu.tabs.allSatisfy { $0.url.count <= Limit.maxURL && $0.name.count <= Limit.maxText }
        }
        let factsFit = facts.uiSupport.count <= Limit.maxCapabilities && facts.uiSupport.keys.allSatisfy { $0.count <= 64 }
            && [facts.model, facts.marketedModel, facts.language].allSatisfy { ($0?.count ?? 0) <= 64 }
            && (facts.bandTitles ?? []).count <= 8 && (facts.bandTitles ?? []).allSatisfy { $0.count <= 32 }
            && (facts.bandList ?? []).count <= 8 && (facts.bandList ?? []).allSatisfy { $0.count <= 16 }
        let notesFit = notes.count <= 8 && notes.allSatisfy { $0.count <= 2_000 }
        guard menusFit, factsFit, notesFit else { throw RouterMenuEvaluator.Failure.tooLarge }
        return self
    }
}
