# Ingestion exclusion for repetitive xrpld lines (2026-11-16). gcplogs-docker-driver
# grew from ~70 to ~168 GiB/month between early October and mid-November as network
# traffic rose, billed at $0.50/GiB above the project's free 50 GiB. Six line
# patterns were about 84-91% of the bytes in live samples (2026-11-16):
#   Validations:WRN  "Need validated ledger for preferred ledger analysis"
#   LedgerConsensus:NFO "No change (YES|NO) on <amendment>" (per-round vote echo)
#   NetworkOPs:NFO   "Transaction is obsolete", "ConsensusLogger Heartbeat Timer"
#   Protocol:NFO     peer chatter (Marking transaction as BAD, processLedgerRequest)
#   Validations:NFO  "Byzantine Behavior Detector: untrusted" (non-UNL validators)
# Everything else is kept: the consensus narrative (Entering consensus, We closed
# at, Proposers, mode changes), every ERR and other WRN, and the startup banner.
#
# The two absence alerts in monitoring.tf keep their input even without relying on
# how log-based metrics treat excluded entries: a 3-minute live sample left 550
# LedgerConsensus lines (validator/consensus_activity) and 822 lines total
# (validator/log_presence) after this filter.
#
# Rollback: set disabled = true (or remove) and apply. Excluded lines are not
# stored anywhere; the node's own view is via admin RPC over IAP.
resource "google_logging_project_exclusion" "xrpld_repetitive" {
  project     = module.validator.project_id
  name        = "xrpld-repetitive-lines"
  description = "Drops six repetitive xrpld line patterns from gcplogs-docker-driver ingestion; consensus narrative, errors and other warnings are kept (logging.tf)."
  filter      = "logName=\"${local.validator_gcplogs}\" AND jsonPayload.message=~\"Validations:WRN Need validated ledger for preferred ledger analysis|LedgerConsensus:NFO No change |NetworkOPs:NFO Transaction is obsolete|NetworkOPs:NFO ConsensusLogger Heartbeat Timer| Protocol:NFO |Validations:NFO Byzantine Behavior Detector: untrusted\""
}
