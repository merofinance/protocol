# Mero Protocol

This is the official repository for the [Mero protocol](https://mero.finance/) contracts.

In addition to the code, check out the official [Mero documentation](https://docs.mero.finance/) as well as the [Mero developers documentation](https://developers.mero.finance/), and the [list of deployed contracts](https://developers.mero.finance/deployed-contracts.html).

The [test suite](tests) repository is built with [Pytest](https://docs.pytest.org/en/6.2.x/), which is used by [Brownie](https://eth-brownie.readthedocs.io/en/stable/toctree.html).

The test suite relies on the following packages:

- [eth-brownie](https://github.com/eth-brownie/brownie): Testing framework for solidity and vyper code written in Python using Pytest
- [brownie-token-tester](https://github.com/iamdefinitelyahuman/brownie-token-tester): Custom mint logic for ERC20 tokens in `mainnet-fork` mode

### Getting Started

To get started using this repository, install the requirements (presumably in a virtual enviroment):

```
pip install -r requirements.txt
```

To run the full test suite, run:

```
brownie test
```

For a more detailed overview of how the Mero protocol can be tested, please read the [test suite documentation](tests/README.md).

To compile all contracts, run:

```
brownie compile
```

For a detailed overview of how to use Brownie, please check out the [official docs](https://eth-brownie.readthedocs.io/en/stable/toctree.html).

### Repository Structure

All Mero contracts are located within the [`contracts`](contracts) directory.

The tests are located within the [`tests`](tests) directory. The different liquidity pools that exist are specified in the tests directory [here](tests/configs).

### Environment Variables

The required environments variables that need to be set for running the test suite are listed [here](.env.example).

_Note_: The `ETHERSCAN_TOKEN` environment variable may need to be specified when running tests in `mainnet-fork` mode, as Etherscan is used to fetch the latest contract data and the API request limit may be reached.

