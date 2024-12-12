# SmartContract template [![TEST](https://github.com/tnkshuuhei/foundry-template/actions/workflows/test.yaml/badge.svg?branch=main)](https://github.com/tnkshuuhei/foundry-template/actions/workflows/test.yaml) [![Slither Analysis](https://github.com/tnkshuuhei/foundry-template/actions/workflows/slither.yaml/badge.svg)](https://github.com/tnkshuuhei/foundry-template/actions/workflows/slither.yaml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Usage

```sh
forge init --template tnkshuuhei/foundry-template my-project
cd my-project
forge install && pnpm install
cp .env.example .env
```

This is a list of the most frequently needed commands.

### Build

Build the contracts:

```sh
pnpm build
```

### Clean

Delete the build artifacts and cache directories:

```sh
pnpm clean
```

### Compile

Compile the contracts:

```sh
pnpm build
```

### Coverage

Get a test coverage report:

```sh
pnpm coverage
```

### Gas Usage

Get a gas report:

```sh
forge test --gas-report
```

### Test

Run the tests:

```sh
pnpm test
```
