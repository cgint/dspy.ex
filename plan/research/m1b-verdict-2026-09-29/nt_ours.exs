xs = Jason.decode!(File.read!(System.get_env("BAT")))
File.write!(System.get_env("OUT"), Jason.encode!(Enum.map(xs, &Dspy.Metrics.normalize_text/1)))
