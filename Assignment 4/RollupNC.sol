pragma solidity ^0.5.0;

import "../build/Update_verifier.sol";
import "../build/Withdraw_verifier.sol";

contract IMiMC {
    function MiMCpe7(uint256, uint256) public pure returns (uint256) {}
}

contract IMiMCMerkle {
    uint256[16] public zeroCache;

    function getRootFromProof(
        uint256,
        uint256[] memory,
        uint256[] memory
    ) public view returns (uint256) {}

    function hashMiMC(uint256[] memory) public view returns (uint256) {}
}

contract ITokenRegistry {
    address public coordinator;
    uint256 public numTokens;
    mapping(address => bool) public pendingTokens;
    mapping(uint256 => address) public registeredTokens;
    modifier onlyCoordinator() {
        assert(msg.sender == coordinator);
        _;
    }

    function registerToken(address tokenContract) public {}

    function approveToken(address tokenContract) public onlyCoordinator {}
}

contract IERC20 {
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public returns (bool) {}

    function transfer(address recipient, uint256 value) public returns (bool) {}
}

contract RollupNC is Update_verifier, Withdraw_verifier {
    IMiMC public mimc;
    IMiMCMerkle public mimcMerkle;
    ITokenRegistry public tokenRegistry;
    IERC20 public tokenContract;

    uint256 public currentRoot;
    address public coordinator;
    uint256[] public pendingDeposits;
    uint256 public queueNumber;
    uint256 public depositSubtreeHeight;
    uint256 public updateNumber;

    uint256 public BAL_DEPTH = 4;
    uint256 public TX_DEPTH = 2;

    // (queueNumber => [pubkey_x, pubkey_y, balance, nonce, token_type])
    mapping(uint256 => uint256) public deposits; //leaf idx => leafHash
    mapping(uint256 => uint256) public updates; //txRoot => update idx

    event RegisteredToken(uint256 tokenType, address tokenContract);
    event RequestDeposit(uint256[2] pubkey, uint256 amount, uint256 tokenType);
    event UpdatedState(uint256 currentRoot, uint256 oldRoot, uint256 txRoot);
    event Withdraw(uint256[9] accountInfo, address recipient);

    constructor(
        address _mimcContractAddr,
        address _mimcMerkleContractAddr,
        address _tokenRegistryAddr
    ) public {
        mimc = IMiMC(_mimcContractAddr);
        mimcMerkle = IMiMCMerkle(_mimcMerkleContractAddr);
        tokenRegistry = ITokenRegistry(_tokenRegistryAddr);
        currentRoot = mimcMerkle.zeroCache(BAL_DEPTH);
        coordinator = msg.sender;
        queueNumber = 0;
        depositSubtreeHeight = 0;
        updateNumber = 0;
    }

    modifier onlyCoordinator() {
        assert(msg.sender == coordinator);
        _;
    }

    /// @Dev executed by coordinator to verify SNARK proof that
    /// account merkle root is updated correcly by transactions.
    /// @param input[0]: new merkle root after applying the transactions
    /// @param input[1]: transaction merkle tree root
    /// @param input[2]: old merkle root before applying the transactions
    /// @param a, b, c:　merkle proof parameters
    function updateState(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[3] memory input
    ) public onlyCoordinator {
        require(currentRoot == input[2], "input does not match current root");
        //validate proof
        require(update_verifyProof(a, b, c, input), "SNARK proof is invalid");
        // update merkle root
        currentRoot = input[0];
        // save transaction root to onchain map `updates`
        updateNumber++;
        updates[input[1]] = updateNumber;
        emit UpdatedState(input[0], input[1], input[2]); //newRoot, txRoot, oldRoot
    }

    /// @Dev User tries to deposit ERC20 tokens
    /// @param pubkey: user's public key
    /// @param amount: deposit amount
    /// @param tokenType: 0 (coodinator only), 1 (ETH),  >1 (ERC20 token)
    function deposit(
        uint256[2] memory pubkey,
        uint256 amount,
        uint256 tokenType
    ) public payable {
        // verify token types and transfer token
        // to the fund pool managed by this contract address
        if (tokenType == 0) {
            require(
                msg.sender == coordinator,
                "tokenType 0 is reserved for coordinator"
            );
            require(
                amount == 0 && msg.value == 0,
                "tokenType 0 does not have real value"
            );
        } else if (tokenType == 1) {
            require(
                msg.value > 0 && msg.value >= amount,
                "msg.value must at least equal stated amount in wei"
            );
        } else if (tokenType > 1) {
            require(amount > 0, "token deposit must be greater than 0");
            address tokenContractAddress = tokenRegistry.registeredTokens(
                tokenType
            );
            tokenContract = IERC20(tokenContractAddress);
            require(
                tokenContract.transferFrom(msg.sender, address(this), amount),
                "token transfer not approved"
            );
        }

        // hashes [eddsa_pubkey, amount, nonce = 0, tokenType] to get
        // the deposit_leaf (an account_leaf)
        uint256[] memory depositArray = new uint256[](5);
        depositArray[0] = pubkey[0];
        depositArray[1] = pubkey[1];
        depositArray[2] = amount;
        depositArray[3] = 0;
        depositArray[4] = tokenType;

        uint256 depositHash = mimcMerkle.hashMiMC(depositArray);

        // Push deposit_leaf to deposits array
        pendingDeposits.push(depositHash);
        emit RequestDeposit(pubkey, amount, tokenType);
        // Increase deposit queue number
        queueNumber++;

        // hash deposit array into on-chain merkle root and
        // stores in pendingDeposits[0]. also compute tree height.
        // Notice that the number of times a user has to hash is equal
        // to the number of times the deposit queue number (queueNumber)
        // can be divided by 2.
        uint256 tmpDepositSubtreeHeight = 0;
        uint256 tmp = queueNumber;
        while (tmp % 2 == 0) {
            uint256[] memory array = new uint256[](2);
            array[0] = pendingDeposits[pendingDeposits.length - 2];
            array[1] = pendingDeposits[pendingDeposits.length - 1];
            pendingDeposits[pendingDeposits.length - 2] = mimcMerkle.hashMiMC(
                array
            );
            removeDeposit(pendingDeposits.length - 1);
            tmp = tmp / 2;
            tmpDepositSubtreeHeight++;
        }
        if (tmpDepositSubtreeHeight > depositSubtreeHeight) {
            depositSubtreeHeight = tmpDepositSubtreeHeight;
        }
    }

    // coordinator adds certain number of deposits to balance tree
    // coordinator must specify subtree index in the tree since the deposits
    // are being inserted at a nonzero height
    function processDeposits(
        uint256 subtreeDepth,
        uint256[] memory subtreePosition,
        uint256[] memory subtreeProof
    ) public onlyCoordinator returns (uint256) {
        uint256 emptySubtreeRoot = mimcMerkle.zeroCache(subtreeDepth); //empty subtree of height 2
        require(
            currentRoot ==
                mimcMerkle.getRootFromProof(
                    emptySubtreeRoot,
                    subtreePosition,
                    subtreeProof
                ),
            "specified subtree is not empty"
        );
        currentRoot = mimcMerkle.getRootFromProof(
            pendingDeposits[0],
            subtreePosition,
            subtreeProof
        );
        removeDeposit(0);
        queueNumber = queueNumber - 2**depositSubtreeHeight;
        return currentRoot;
    }

    /// @dev user tries to withdraw token.
    /// To start a withdrawal process, user needs to send her tokens to zero address,
    /// then withdraw() contrat function is called to,
    /// 1. Verifies exisitence of a withdraw transaction
    /// 2. Verifies signature
    /// 3. Transfer's money from pool to specified address
    /// @param txInfo: withdrawal info
    /// @param position: merkle path indices to the transaction merkle tree root
    /// @param proof: merkle path values to the transaction merkle tree root
    /// @param recipient: recipient address
    /// @param a, b, c: zk-snark proof
    function withdraw(
        uint256[9] memory txInfo, //[fromX, fromY, index, toX ,toY, nonce, amount, token_type, txRoot]
        uint256[] memory position,
        uint256[] memory proof,
        address payable recipient,
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c
    ) public {
        require(txInfo[7] > 0, "invalid tokenType");
        // Check transaction root is on chain
        require(updates[txInfo[8]] > 0, "txRoot does not exist");

        // Verifies exisitence of a withdraw transaction
        uint256[] memory txArray = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            txArray[i] = txInfo[i];
        }
        uint256 txLeaf = mimcMerkle.hashMiMC(txArray);
        require(
            txInfo[8] == mimcMerkle.getRootFromProof(txLeaf, position, proof),
            "transaction does not exist in specified transactions root"
        );

        // message is hash of nonce and recipient address
        uint256[] memory msgArray = new uint256[](2);
        msgArray[0] = txInfo[5];
        msgArray[1] = uint256(recipient);
        // Verify signature.
        // May not need to use zk-snark proof and can be done
        // in contract directly
        require(
            withdraw_verifyProof(
                a,
                b,
                c,
                [txInfo[0], txInfo[1], mimcMerkle.hashMiMC(msgArray)]
            ),
            "eddsa signature is not valid"
        );

        // transfer token on tokenContract
        if (txInfo[7] == 1) {
            // ETH
            recipient.transfer(txInfo[6]);
        } else {
            // ERC20
            address tokenContractAddress = tokenRegistry.registeredTokens(
                txInfo[7]
            );
            tokenContract = IERC20(tokenContractAddress);
            require(
                tokenContract.transfer(recipient, txInfo[6]),
                "transfer failed"
            );
        }

        emit Withdraw(txInfo, recipient);
    }

    //call methods on TokenRegistry contract

    function registerToken(address tokenContractAddress) public {
        tokenRegistry.registerToken(tokenContractAddress);
    }

    function approveToken(address tokenContractAddress) public onlyCoordinator {
        tokenRegistry.approveToken(tokenContractAddress);
        emit RegisteredToken(tokenRegistry.numTokens(), tokenContractAddress);
    }

    // helper functions
    function removeDeposit(uint256 index) internal returns (uint256[] memory) {
        require(index < pendingDeposits.length, "index is out of bounds");

        for (uint256 i = index; i < pendingDeposits.length - 1; i++) {
            pendingDeposits[i] = pendingDeposits[i + 1];
        }
        delete pendingDeposits[pendingDeposits.length - 1];
        pendingDeposits.length--;
        return pendingDeposits;
    }
}
