# Install dependencies
setup:
	forge install

# Run tests for TakeProfits.t.sol
test-takeprofits:
	forge test --match-path test/TakeProfits.t.sol -vvvv

