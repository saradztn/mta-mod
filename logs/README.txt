SentinelAC log directory
========================

sentinel.log      - main log (DEBUG / INFO / WARNING / DETECTION / CRITICAL)
sentinel.log.old  - previous log after size rotation (Config.Logging.MaxFileSizeKB)
state.dat         - resource guard state file ("running" / "stopped") used to detect
                    unclean shutdowns of the anti-cheat itself.
firewall_baseline.json - learned event/argument-signature consensus baseline of the event firewall
                    (counts only, no serials). Delete it to restart learning.

Files are created automatically by the resource. Do not include them in meta.xml.
Evidence samples are written inline as JSON in DETECTION entries (Config.Evidence.WriteToLog).
