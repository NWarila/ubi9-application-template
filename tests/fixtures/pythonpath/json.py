with open(__import__("os").environ["HOSTILE_RUNTIME_SPY"], "a", encoding="utf-8") as stream:
    stream.write("json\n")
