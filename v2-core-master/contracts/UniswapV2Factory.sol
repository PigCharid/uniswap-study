pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {

    // 手续费地址
    address public feeTo;

    // 手续费设置地址
    address public feeToSetter;

    // 合约池配对映射
    mapping(address => mapping(address => address)) public getPair;
    
    // 所有的流动池 
    address[] public allPairs;

    // 创建事件
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    // 构造函数  传入手续费管理员地址
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    // 多少合约
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    // 创建流动池
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // tokenA和B不能为同一个
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 排序一下 地址小的在前面
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 不能为0地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 为创建
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        
        // 合约类型的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;

        // 把token0和token1进行encodePacked然后keccak256  当作salt
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // 内联汇编 创建一个合约
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 然后调用合约进行初始化
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 双向存入
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 总合约数组
        allPairs.push(pair);
        // 触发创建事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 设置手续费的收款地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    // 设置手续费的管理地址
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
