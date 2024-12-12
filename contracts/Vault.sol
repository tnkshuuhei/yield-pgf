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

/// @notice Emitted when the amount of shares being minted to receiver is greater than the max amount allowed
/// @param shares The shares being minted
/// @param receiver The receiver address
/// @param max The max amount of shares that can be minted to the receiver
error MintGTMax(uint256 shares, address receiver, uint256 max);

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

    /**
     * @notice Emitted when a user sponsor the Vault.
     * @param caller Address that called the function
     * @param receiver Address receiving the Vault shares
     * @param assets Amount of assets deposited into the Vault
     * @param shares Amount of shares minted to `receiver`
     */
    event Sponsor(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

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
    /* ============ Internal Functions ============ */

    /* ============ Deposit Functions ============ */

    /**
     * @notice Deposit/mint common workflow.
     * @dev If there are currently some underlying assets in the vault,
     *      we only transfer the difference from the user wallet into the vault.
     *      The difference is calculated this way:
     *      - if `_vaultAssets` balance is greater than 0 and lower than `_assets`,
     *        we substract `_vaultAssets` from `_assets` and deposit `_assetsDeposit` amount into the vault
     *      - if `_vaultAssets` balance is greater than or equal to `_assets`,
     *        we know the vault has enough underlying assets to fulfill the deposit
     *        so we don't transfer any assets from the user wallet into the vault
     */
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal virtual override {
        IERC20 _asset = IERC20(asset());
        uint256 _vaultAssets = _asset.balanceOf(address(this));

        // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.

        // We only need to deposit new assets if there is not enough assets in the vault to fulfill the deposit
        if (_assets > _vaultAssets) {
            uint256 _assetsDeposit;

            unchecked {
                if (_vaultAssets != 0) {
                    _assetsDeposit = _assets - _vaultAssets;
                }
            }

            SafeERC20.safeTransferFrom(_asset, _caller, address(this), _assetsDeposit != 0 ? _assetsDeposit : _assets);
        }

        _yieldVault.deposit(_assets, address(this));
        _mint(_receiver, _shares);

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    /**
     * @notice Compute the amount of assets to deposit before minting `_shares`.
     * @param _shares Amount of shares to mint
     * @param _receiver Address of the receiver of the vault shares
     * @return uint256 Amount of assets to deposit.
     */
    function _beforeMint(uint256 _shares, address _receiver) internal view returns (uint256) {
        if (_shares > maxMint(_receiver)) revert MintGTMax(_shares, _receiver, maxMint(_receiver));
        return _convertToAssets(_shares, Math.Rounding.Ceil);
    }

    /**
     * @notice Deposit assets into the Vault and delegate to the sponsorship address.
     * @param _assets Amount of assets to deposit
     * @param _receiver Address of the receiver of the vault shares
     * @return uint256 Amount of shares minted to `_receiver`.
     */
    function _sponsor(uint256 _assets, address _receiver) internal returns (uint256) {
        uint256 _shares = deposit(_assets, _receiver);

        if (_twabController.delegateOf(address(this), _receiver) != _twabController.SPONSORSHIP_ADDRESS()) {
            _twabController.sponsor(_receiver);
        }

        emit Sponsor(msg.sender, _receiver, _assets, _shares);

        return _shares;
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
