// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626, ERC20, IERC20, IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20Permit, IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { TwabController } from "./TwabController.sol";

/// @notice Emitted when the TWAB controller is set to the zero address
error TwabControllerZeroAddress();

/// @notice Emitted when the Yield Vault is set to the zero address
error YieldVaultZeroAddress();

/// @notice Emitted when the Owner is set to the zero address
error OwnerZeroAddress();

/// @notice Emitted when the yield fee percentage being set is greater than the fee precision
/// @param yieldFeePercentage The yield fee percentage in integer format
/// @param feePrecision The fee precision
error YieldFeePercentageGTPrecision(uint256 yieldFeePercentage, uint256 feePrecision);

contract Vault is ERC4626, ERC20Permit, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* ============ Events ============ */

    /**
     * @notice Emitted when a new Vault has been deployed.
     * @param asset Address of the underlying asset used by the vault
     * @param name Name of the ERC20 share minted by the vault
     * @param symbol Symbol of the ERC20 share minted by the vault
     * @param twabController Address of the TwabController used to keep track of balances
     * @param yieldVault Address of the ERC4626 vault in which assets are deposited to generate yield
     * @param claimer Address of the claimer
     * @param yieldFeeRecipient Address of the yield fee recipient
     * @param yieldFeePercentage Yield fee percentage
     * @param owner Address of the owner
     */
    event NewVault(
        IERC20 indexed asset,
        string name,
        string symbol,
        TwabController twabController,
        IERC4626 indexed yieldVault,
        address claimer,
        address yieldFeeRecipient,
        uint256 yieldFeePercentage,
        address owner
    );
    /* ============ Variables ============ */

    /// @notice Address of the TwabController used to keep track of balances.
    TwabController private immutable _twabController;

    /// @notice Address of the ERC4626 vault generating yield.
    IERC4626 private immutable _yieldVault;

    /// @notice Address of the claimer.
    address private _claimer;

    /// @notice Underlying asset unit (i.e. 10 ** 18 for DAI).
    uint256 private _assetUnit;

    /// @notice Yield fee percentage represented in 9 decimal places and in decimal notation (i.e. 10000000 = 0.01 =
    /// 1%).
    uint256 private _yieldFeePercentage;

    /// @notice Address of the yield fee recipient that receives the fee amount when yield is captured.
    address private _yieldFeeRecipient;

    /// @notice Total supply of accrued yield fee.
    uint256 private _yieldFeeTotalSupply;

    /// @notice Fee precision denominated in 9 decimal places and used to calculate yield fee percentage.
    uint256 private constant FEE_PRECISION = 1e9;

    /* ============ Constructor ============ */

    /**
     * @notice Vault constructor
     * @dev `claimer` can be set to address zero if none is available yet.
     * @param _asset Address of the underlying asset used by the vault
     * @param _name Name of the ERC20 share minted by the vault
     * @param _symbol Symbol of the ERC20 share minted by the vault
     * @param twabController_ Address of the TwabController used to keep track of balances
     * @param yieldVault_ Address of the ERC4626 vault in which assets are deposited to generate yield
     * @param claimer_ Address of the claimer
     * @param yieldFeeRecipient_ Address of the yield fee recipient
     * @param yieldFeePercentage_ Yield fee percentage
     * @param _owner Address that will gain ownership of this contract
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        TwabController twabController_,
        IERC4626 yieldVault_,
        address claimer_,
        address yieldFeeRecipient_,
        uint256 yieldFeePercentage_,
        address _owner
    )
        ERC4626(_asset)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
        Ownable(_owner)
    {
        require((address(twabController_) != address(0)), TwabControllerZeroAddress());
        require((address(yieldVault_) != address(0)), YieldVaultZeroAddress());
        require((address(_owner) != address(0)), OwnerZeroAddress());

        _twabController = twabController_;
        _yieldVault = yieldVault_;

        _setClaimer(claimer_);
        _setYieldFeeRecipient(yieldFeeRecipient_);
        _setYieldFeePercentage(yieldFeePercentage_);

        _assetUnit = 10 ** super.decimals();

        // Approve once for max amount
        _asset.safeIncreaseAllowance(address(yieldVault_), type(uint256).max);

        emit NewVault(
            _asset,
            _name,
            _symbol,
            twabController_,
            yieldVault_,
            claimer_,
            yieldFeeRecipient_,
            yieldFeePercentage_,
            _owner
        );
    }

    /* ============ External Functions ============ */

    /* ============ View Functions ============ */
    /**
     * @notice Total available yield amount accrued by this vault.
     * @dev This amount includes the liquidatable yield + yield fee amount.
     * @dev The available yield is equal to the total amount of assets managed by this Vault
     *      minus the total amount of assets supplied to the Vault and yield fees allocated to `_yieldFeeRecipient`.
     * @dev If `_sharesToAssets` is greater than `_assets`, it means that the Vault is undercollateralized.
     *      We must not mint more shares than underlying assets available so we return 0.
     * @return uint256 Total yield amount
     */
    function availableYieldBalance() public view returns (uint256) {
        uint256 _assets = _totalAssets();
        uint256 _sharesToAssets = _convertToAssets(_totalShares(), Math.Rounding.Floor);

        return _sharesToAssets > _assets ? 0 : _assets - _sharesToAssets;
    }

    /**
     * @notice Get the available yield fee amount accrued by this vault.
     * @return uint256 Yield fee amount
     */
    function availableYieldFeeBalance() public view returns (uint256) {
        uint256 _availableYield = availableYieldBalance();

        if (_availableYield != 0 && _yieldFeePercentage != 0) {
            return _availableYieldFeeBalance(_availableYield);
        }

        return 0;
    }

    /// @inheritdoc ERC20
    function balanceOf(address _account) public view virtual override(ERC20, IERC20) returns (uint256) {
        return _twabController.balanceOf(address(this), _account);
    }

    /// @inheritdoc ERC4626
    function decimals() public view virtual override(ERC4626, ERC20) returns (uint8) {
        return super.decimals();
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssets();
    }

    /// @inheritdoc ERC20
    function totalSupply() public view virtual override(ERC20, IERC20) returns (uint256) {
        return _totalSupply();
    }

    /**
     * @notice Total amount of assets managed by this Vault.
     * @dev The total amount of assets managed by this vault is equal to
     *      the amount of assets managed by the YieldVault + the amount living in this vault.
     */
    function _totalAssets() internal view returns (uint256) {
        return _yieldVault.maxWithdraw(address(this)) + super.totalAssets();
    }

    /**
     * @notice Total amount of shares minted by this Vault.
     * @return uint256 Total amount of shares
     */
    function _totalSupply() internal view returns (uint256) {
        return _twabController.totalSupply(address(this));
    }

    /**
     * @notice Total amount of shares managed by this Vault.
     * @dev Equal to the total amount of shares minted by this Vault
     *      + the total amount of yield fees allocated by this Vault.
     * @return uint256 Total amount of shares
     */
    function _totalShares() internal view returns (uint256) {
        return _totalSupply() + _yieldFeeTotalSupply;
    }

    /**
     * @notice Available yield fee amount.
     * @param _availableYield Total amount of yield available
     * @return uint256 Available yield fee balance
     */
    function _availableYieldFeeBalance(uint256 _availableYield) internal view returns (uint256) {
        return (_availableYield * _yieldFeePercentage) / FEE_PRECISION;
    }

    /* ============ Setter Functions ============ */
    /**
     * @notice Set claimer address.
     * @param claimer_ Address of the claimer
     */
    function _setClaimer(address claimer_) internal {
        _claimer = claimer_;
    }

    /**
     * @notice Set yield fee percentage.
     * @dev Yield fee is represented in 9 decimals and can't exceed `1e9`.
     * @param yieldFeePercentage_ Yield fee percentage
     */
    function _setYieldFeePercentage(uint256 yieldFeePercentage_) internal {
        require(yieldFeePercentage_ <= FEE_PRECISION, YieldFeePercentageGTPrecision(yieldFeePercentage_, FEE_PRECISION));
        _yieldFeePercentage = yieldFeePercentage_;
    }

    /**
     * @notice Set yield fee recipient address.
     * @param yieldFeeRecipient_ Address of the fee recipient
     */
    function _setYieldFeeRecipient(address yieldFeeRecipient_) internal {
        _yieldFeeRecipient = yieldFeeRecipient_;
    }
}
