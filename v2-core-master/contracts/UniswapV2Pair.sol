pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    // 安全数学
    using SafeMath  for uint;
    // 这里研究一下    好像是和浮点数相关
    using UQ112x112 for uint224;
    // 最小流动性 1000
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 转账函数的函数选择器的bytes4
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 工厂合约的地址
    address public factory;
    // 配对的token地址
    address public token0;
    address public token1;

    // 储备量
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves

    // 区块时间？
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    // 价格  啥意思
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    
    // 储备量相乘获取K值
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // 锁
    uint private unlocked = 1;
    // 锁的修饰器
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 获取储备量及获取的时间
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 转账 转出
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 这几个数据我要获取一下
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    // 铸造事件
    event Mint(address indexed sender, uint amount0, uint amount1);
    
    // 燃烧事件
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    
    // 交换事件
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );

    // 同步
    event Sync(uint112 reserve0, uint112 reserve1);

    // 构造函数 看清楚msg.sender到底是什么
    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 流动池初始化
    function initialize(address _token0, address _token1) external {
        // 只能由工厂合约调用
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        // token的赋值
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // 更新储备量
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 更新时间记录
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 时间间隔
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 时间符合   储备量符合
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 这里暂时没懂
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新储备量
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        // 更新时间记录
        blockTimestampLast = blockTimestamp;
        // 触发同步事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // 如果收取费用，则铸币流动性相当于sqrt（k）增长的1/6
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 获取手续费收款地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // 赋值并判断     这里啊   如果结果是0地址的话会出现什么状况
        feeOn = feeTo != address(0);
        // 获取K值
        uint _kLast = kLast; // gas savings
        // 确实手续费的按钮打开了
        if (feeOn) {
            // K值不为0
            if (_kLast != 0) {
                // 计算两个值
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity); //这个给手续费的方式是铸造流动性给收款地址
                }
            }
        } else if (_kLast != 0) {   
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 这个低级函数应该从执行重要安全检查的合同中调用   
    function mint(address to) external lock returns (uint liquidity) {
        // 获取储备量    
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 获取合约地址里面的token月
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // 为啥要用余额减去储备量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
        // 手续费的操作
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取LP总数
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 为0是什么情况
        if (_totalSupply == 0) {
            // 算出了个啥
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 给0地址铸造最小的发行数量    
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 算出liquidity
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 需要流动性大于0
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 给对方地址铸造流动性代币
        _mint(to, liquidity);

        // 更新余额和储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果手续费开关打开的的话  重新计算K值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 这个低级函数应该从执行重要安全检查的合同中调用
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 获取token的地址   通过接受到内存中来能够节省手续费
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings

        // 看看余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        
        // 看看还要多少的流动性
        uint liquidity = balanceOf[address(this)];
        // 手续费扣掉
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取总的LP的铸造数量
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 赎回的计算方式么
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        // 数量不能太小
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 合约地址的流动性减少
        _burn(address(this), liquidity);
        // 把钱转给接受之
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // 更新余额和储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 手续费打开了的话 K值重新计算
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 交换   需要重点研究一下
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 必须有一个大于0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
        

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        // 拿到token的地址
        address _token0 = token0;
        address _token1 = token1;
        // 接收者不是token地址
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        // 查看这个合约的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // 撤池么
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 强制更新
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
