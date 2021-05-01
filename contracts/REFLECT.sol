/*
 * Copyright © 2020 reflect.finance. ALL RIGHTS RESERVED.
 */

pragma solidity ^0.6.2;

import "openzeppelin-solidity/contracts/GSN/Context.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/Address.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";

contract REFLECT is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    // _rOwned represents the amount of reflections owned which
    // represents some amount of actual tokens owned via a ratio.
    // For example, if the ratio is 2 reflections equals 1 token, then you can
    // send up to 1 token if you own 2 reflections.
    // Change of this ratio is what allowed hodlers to increase the amount of token
    // they own over time due to transaction tax since updating everyone's balance 
    // is impossible otherwise.
    // While the amount of reflections owned stays the same,
    // the ratio between reflections and actual token can change (i.e. it increases
    // over time) and therefore you can spend more token with the same amount
    // of reflections owned.
    mapping (address => uint256) private _rOwned;
    // _tOwned represents the actual amount of tokens owned and 
    // is ONLY used for address that are excluded from reflection reward.
    // _tOwned for non-excluded address is always 0.
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    // This 2 variables keep track of the address(es) excluded from receiving reflection
    // reward, as controlled by includeAccount(address account) and excludeAccount(address account).
    // Excluded address(es) will have their transaction bound by _tOwned instead of _rOwned.
    mapping (address => bool) private _isExcluded;
    address[] private _excluded;
   
    // MAX is maximum of uint256 - 1
    uint256 private constant MAX = ~uint256(0);
    // _tTotal is the initial total token supply in the unit of the smallest divisible unit
    uint256 private constant _tTotal = 10 * 10**6 * 10**9;
    // _rTotal is the maximum amount of reflections owned.
    // By using (MAX - (MAX % _tTotal)), it make sures that _rTotal is initially the
    // biggest uint256 integer that are divisible by _tTotal
    // (i.e. _tTotal * k = _rTotal, where k is an integer).
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    // _tFeeTotal represents the total amount of token (NOT reflection) burned due to transaction tax.
    // The current circulating supply is (_tTotal - _tFeeTotal).
    uint256 private _tFeeTotal;

    string private _name = 'reflect.finance';
    string private _symbol = 'RFI';
    uint8 private _decimals = 9;

    constructor () public {
        // This grants the contract deployed with the total token supply as defined by _tTotal.
        // This is because balanceOf() of the address with _rTotal will always returned _tTotal.
        _rOwned[_msgSender()] = _rTotal;
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        // For excluded address, their token balance is represented by _tOwned variable.
        // Although they will still own reflections via _rOwned variable, any transactions by
        // excluded address requires them to have sufficient token in _tOwned variable and therefore
        // the amount of reflections they own via _rOwned doesn't matter.
        if (_isExcluded[account]) return _tOwned[account];
        // For any other address, their token balance is represented by the amount of reflections
        // owned represented by the _rOwned variable.
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        // Returns whether an address is excluded from reflection reward
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        // Returns the total amount of fees burned due to transaction tax
        return _tFeeTotal;
    }

    // Anyone can call this function to burn tAmount of token similar to transaction tax.
    // Burning token via this function will increase the ratio between reflection and actual
    // token.
    function reflect(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");
        // Get the equivalent amount of reflection to the tAmount of token
        (uint256 rAmount,,,,) = _getValues(tAmount);
        // Subtract the amount of reflection from the account
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        // Reduce the total amount of reflection (which is going to increase the ratio)
        _rTotal = _rTotal.sub(rAmount);
        // Increment the token burned variable
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    // Convert tAmount of token to its equivalent amount of reflection, before or after the 1% transaction fee
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            // Get the equivalent amount of reflection to the tAmount of token without fee included
            (uint256 rAmount,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            // Get the equivalent amount of reflection to the tAmount of token with fee included
            (,uint256 rTransferAmount,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    // Convert rAmount of reflection to its equivalent amount of actual token
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        // Get the conversion rate between reflection and actual token
        uint256 currentRate =  _getRate();
        // Divide rAmount by the rate to get its equivalent amount of actual token
        return rAmount.div(currentRate);
    }

    // Exclude the address account from receiving reflection reward
    function excludeAccount(address account) external onlyOwner() {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            // When an address is excluded, its transaction will be bounded by
            // _tOwned variable instead of the _rOwned variable.
            // tokenFromReflection(_rOwned[account]) will return an amount
            // of actual token owned by the address via reflection.
            // For example, if the address own 2 reflection and 1 reflection represents
            // 0.5 actual token, then tokenFromReflection should return 1.
            // We then set _tOwned to be 1 to represent that this address
            // own 1 actual token.
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        // Include the excluded address in _isExcluded and _excluded variable.
        // It will become obvious why we need 2 distinct variable for storing the same thing later on.
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    // Include an excluded address to receive reflection reward
    function includeAccount(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            // Loop until we found the excluded address in the _excluded array
            if (_excluded[i] == account) {
                // Place last element in _excluded to the original excluded address position
                _excluded[i] = _excluded[_excluded.length - 1];
                // Set _tOwned to 0 since it is no longer needed
                _tOwned[account] = 0;
                // Remove the address from _isExcluded
                _isExcluded[account] = false;
                // Pop the last element in the _excluded array (which is already placed back in the array)
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // Handling the actual token transfer
    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            // Transfer from excluded address to normal address
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            // Transfer from normal address to excluded address
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            // Transfer between normal addresses
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            // Transfer between excluded addresses
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
    }

    // Handling transfer between normal addresses
    // For normal addresses, we only need to modify _rOwned, i.e. the amount of reflection owned
    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        // Get the amount of reflection to be deducted from sender (rAmount), the amount of reflection to be added to recipient (rTransferAmount),
        // the amount of reflection burned as fee (rFee) where rAmount = rTransferAmount + rFee,
        // the amount of actual token to be added to recipient (tTransferAmount) which should be equivalent to the amount of token represented by rTransferAmount,
        // and the amount of actual token burned as fee (tFee) which should be equivalent to the amount of token represented by rFee
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount);
        // Subtract rAmount from sender
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        // Add rTransferAmount to recipient
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        // Modify _rTotal and _tFeeTotal variables
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    // Handling transfer from normal address to excluded addresses
    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        // Get the amount of reflection to be deducted from sender (rAmount), the amount of reflection to be added to recipient (rTransferAmount),
        // the amount of reflection burned as fee (rFee) where rAmount = rTransferAmount + rFee,
        // the amount of actual token to be added to recipient (tTransferAmount) which should be equivalent to the amount of token represented by rTransferAmount,
        // and the amount of actual token burned as fee (tFee) which should be equivalent to the amount of token represented by rFee
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount);
        // Subtract reflection from normal address sebder
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        // Increase actual amount of token sent to the excluded address
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        // Increase the amount of reflection sent to the excluded address
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        // Modify _rTotal and _tFeeTotal variables
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    // Handling transfer from excluded address to normal address
    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        // Get the amount of reflection to be deducted from sender (rAmount), the amount of reflection to be added to recipient (rTransferAmount),
        // the amount of reflection burned as fee (rFee) where rAmount = rTransferAmount + rFee,
        // the amount of actual token to be added to recipient (tTransferAmount) which should be equivalent to the amount of token represented by rTransferAmount,
        // and the amount of actual token burned as fee (tFee) which should be equivalent to the amount of token represented by rFee
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount);
        // Subtract actual token and reflection owned from sender
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        // Increment reflection owned by recipient
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
        // Modify _rTotal and _tFeeTotal variables
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    // Handling transfer between excluded address
    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        // Get the amount of reflection to be deducted from sender (rAmount), the amount of reflection to be added to recipient (rTransferAmount),
        // the amount of reflection burned as fee (rFee) where rAmount = rTransferAmount + rFee,
        // the amount of actual token to be added to recipient (tTransferAmount) which should be equivalent to the amount of token represented by rTransferAmount,
        // and the amount of actual token burned as fee (tFee) which should be equivalent to the amount of token represented by rFee
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount);
        // Subtract actual token and reflection owned from sender
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        // Add actual token and reflection transferred to recipient
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        // Modify _rTotal and _tFeeTotal variables
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    // Used to update _rTotal and _tFeeTotal after transaction tax is applied
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    // From the amount of token of transferred (tAmount),
    // return the equivalent amount of reflection transferred before fee,
    // the equivalent amount of reflection transferred after fee,
    // the amount of reflection to be burned as fee,
    // the amount of token to be rewarded to recipient after fee,
    // and the amount of token to be burned as fee
    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256) {
        // Get the amount of token to be rewarded to recipient after fee, and the amount of token to be burned as fee
        (uint256 tTransferAmount, uint256 tFee) = _getTValues(tAmount);
        // Get the current conversion rate between reflection and actual token
        uint256 currentRate =  _getRate();
        // Get the equivalent amount of reflection transferred before fee,  
        // the equivalent amount of reflection transferred after fee,
        // and the amount of reflection to be burned as fee
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, currentRate);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee);
    }

    // From the amount of token to be transferred, get the amount of token to be rewarded to recipient (tTransferAmount),
    // and the amount of token that was burnt as fee (tFee)
    function _getTValues(uint256 tAmount) private pure returns (uint256, uint256) {
        // RFI always burn 1% of transaction amount as fee
        uint256 tFee = tAmount.div(100);
        // Actual transfer amount = transfer amount - fee
        uint256 tTransferAmount = tAmount.sub(tFee);
        return (tTransferAmount, tFee);
    }

    // Compute actual reflection to be subtracted from sender, rewarded to recipient, and fee burned
    function _getRValues(uint256 tAmount, uint256 tFee, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        // Compute the amount of reflection by multiplying it by the currentRate between reflection and actual token
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee);
        return (rAmount, rTransferAmount, rFee);
    }

    // Get the current ratio between reflection and actual token
    function _getRate() private view returns(uint256) {
        // Get the current supply of reflection and token
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        // The ratio is defined as the supply of reflection / supply of token
        return rSupply.div(tSupply);
    }

    // Get the current reflection and token supply
    function _getCurrentSupply() private view returns(uint256, uint256) {
        // Set rSupply and tSupply as current maximum supply of reflection and token
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        // Loop for all excluded wallet - this is why we need the _excluded array variable
        for (uint256 i = 0; i < _excluded.length; i++) {
            // This statement should never run imo, since the amount of reflection or token
            // owned by a single address should never exceeds total supply of reflection or token
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            // Subtract reflection and token owned by excluded address from rSupply and tSupply
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        // I am still figuring this out, not sure what it did
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
}
