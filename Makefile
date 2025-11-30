########################################
# Makefile Configurations
########################################

# Load environment variables from .env file (RPC URLs, PRIVATE_KEY, etc.)
-include .env

.PHONY: all test clean deploy-testnet deploy-mainnet verify-testnet verify-mainnet deploy-anvil update build snapshot format install reinstall remove config help status fuzz audit anvil 

# Primary target (kept simple to avoid reinstalling libraries every run)
all: build


########################################
# Dependency & Build Commands
########################################

# Clean forge-generated files
clean:
	forge clean

# Remove all installed libraries
remove:
	rm -rf lib

# Install project dependencies
install:
	forge install foundry-rs/forge-std 
	forge install foundry-devops
	forge install smartcontractkit/chainlink-brownie-contracts
	forge install OpenZeppelin/openzeppelin-contracts


# Update all installed forge libraries
update:
	forge update

# Compile smart contracts
build:
	forge build

# Clean and rebuild from scratch
reinstall: remove install build

# Show current configuration
config:
	forge config


########################################
# Testing Commands
########################################

# Run full test suite
test:
	forge test

# Run tests with gas usage reporting
test-gas:
	forge test --gas-report

# Create gas snapshot for optimizations tracking
snapshot:
	forge snapshot

# Apply standard Forge formatting to contracts
format:
	forge fmt

# Run fuzz testing with more iterations
fuzz:
	forge test --fuzz-runs 10000

# Run static analysis (Change contract name as needed)
audit:
	forge inspect DecentralizedStableCoin storage-layout
	forge inspect DSCEngine storage-layout
	forge inspect DecentralizedStableCoin abi
	forge inspect DSCEngine abi

########################################
# Deployment Commands
########################################

# Start local Anvil node
anvil:
	anvil

# Deploy to local Anvil
deploy-anvil:
	@forge script script/DeployDSC.s.sol:DeployDSC \
		--rpc-url $(ANVIL_RPC) \
		--broadcast \
		--private-key $(DEFAULT_ANVIL_PRIVATE_KEY) \
		-vvvv

# Deploy to Monad Testnet
deploy-testnet:
	@echo "Deploying to Monad Testnet..."
	@forge script script/DeployDSC.s.sol:DeployDSC \
		--rpc-url $(MONAD_TESTNET_RPC) \
		--private-key $(MONAD_TESTNET_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# Deploy to Monad Mainnet
deploy-mainnet:
	@echo "Deploying to Monad Mainnet..."
	@forge script script/DeployDSC.s.sol:DeployDSC \
		--rpc-url $(MONAD_MAINNET_RPC) \
		--private-key $(MONAD_MAINNET_PRIVATE_KEY) \
		--broadcast \
		-vvvv

########################################
# Verification Commands
########################################

## Verify & publish contract on Monad testnet via Sourcify
verify-testnet:
	@forge verify-contract \
		--rpc-url $(MONAD_TESTNET_RPC) \
		--verifier sourcify \
		--verifier-url 'https://sourcify-api-monad.blockvision.org/api' \
		--chain-id 10143 \
		$(DEPLOYED_ADDRESS_MONAD_TESTNET) \
		script/Deploy.s.sol:DeployDSC


## Verify & publish contract on Monad mainnet via Sourcify
verify-mainnet:
	@forge verify-contract \
		--rpc-url $(MONAD_MAINNET_RPC) \
		--verifier sourcify \
		--verifier-url 'https://sourcify-api-monad.blockvision.org/api' \
		--chain-id 143 \
		${DEPLOYED_ADDRESS_MONAD_MAINNET} \
		script/Deploy.s.sol:DeployDSC


########################################
# Utility Commands
########################################

# Print all available commands
help:
	@echo "Available commands:"
	@echo "  build        - Compile contracts"
	@echo "  test         - Run test suite"
	@echo "  test-gas     - Run tests with gas report"
	@echo "  deploy-*     - Deploy to various networks"
	@echo "  verify-*     - Verify contracts on explorers"
	@echo "  anvil        - Start local development node"
	@echo "  clean        - Clean build artifacts"
	@echo "  install      - Install dependencies"
	@echo "  update       - Update dependencies"
	@echo "  format       - Format Solidity code"
	@echo "  snapshot     - Create gas snapshot"
	@echo "  config       - Show current configuration"

# Show environment status
status:
	@echo "=== Foundry Configuration ==="
	forge config
	@echo ""
	@echo "=== Installed Dependencies ==="
	ls -la lib/
	@echo ""
	@echo "=== Contract Structure ==="
	tree src/ test/ script/ || ls -la src/ test/ script/