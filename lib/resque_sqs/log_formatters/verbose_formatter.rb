module ResqueSqs
  class VerboseFormatter
    def call(serverity, datetime, progname, msg)
      "*** #{msg}\n"
    end
  end
end
