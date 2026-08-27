package acp_probe_test

import std.unittest.*

@Test
public func testParseOptionsDefault(): Unit {
    let opts = parseOptions([])
    @Expect(opts.prompt, "你好，请用一句话介绍你自己")
    @Expect(opts.cwd, "")
}

@Test
public func testParseOptionsPrompt(): Unit {
    let opts = parseOptions(["--prompt", "hello"])
    @Expect(opts.prompt, "hello")
    @Expect(opts.cwd, "")
}

@Test
public func testParseOptionsCwd(): Unit {
    let opts = parseOptions(["--cwd", "/tmp/demo", "--prompt", "x"])
    @Expect(opts.cwd, "/tmp/demo")
    @Expect(opts.prompt, "x")
}

@Test
public func testParseOptionsUnknownIgnored(): Unit {
    let opts = parseOptions(["--unknown", "whatever", "--prompt", "hi"])
    @Expect(opts.prompt, "hi")
}
