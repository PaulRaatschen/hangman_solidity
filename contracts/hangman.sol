// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract Hangman {
    // -----------------------------------------
    // Constants
    // -----------------------------------------
    uint8 public constant MAX_PLAYERS = 5;
    uint8 public constant MAX_GAMES = 5;
    uint8 public constant MAX_GUESSES = 6;
    uint256 public constant INACTIVITY_THRESHOLD = 15 minutes;
    uint256 public constant VOTING_DURATION = 5 minutes;

    string[] private  WORDS = ["Apple", "Banana", "Cherry", "Durian", "Elderberry"];

    // -----------------------------------------------
    // Game Struct: Stores the state for a single game
    // -----------------------------------------------
    struct Game {
        // Basic info
        string   gameID;             // Human-readable name

        // Players
        address                  creator;         // The address that created this game
        uint8                    maxPlayers;      // Maximum amount of players that can join the game.
        uint8                    currentPlayers;  // Number of players in the game 
        mapping(address => bool) isPlayer;        // Lookup map for players in the game.

        // Hangman-specific data
        string                   hiddenWord;       // Word to guess 
        bool[]                   revealedLetters;  // Tracks which letters in hiddenWord are revealed
        uint8                    guessCount;       // Number of guesses
        mapping(bytes1 => bool)  guessedLetters;   // Letter that have been guessed 

        // Inactivity Tracking
        uint256 lastActionTimestamp;  // The last time this game was interacted with

        // Voting/Election state
        Vote vote;            
    }

    // -----------------------------------------------
    // Vote Struct: Stores the state for a letter vote
    // -----------------------------------------------
    struct Vote {
        bool                       votingActive;        // True when a voting round is active
        uint256                    voteStartTimestamp;  // Timestamp when voting started
        uint8                      voteCount;           // Number of players that voted
        address[MAX_PLAYERS]       playersVoted;        // List of players who have already voted this round
        mapping(address => bytes1) playerVotes;         // Each player's vote for this round
        mapping(bytes1 => uint8)   letterCounts;         // Number of votes for each letter
    }

    // -----------------------------------------------
    // VoteInfo Struct: Describes the vote of a single player
    // -----------------------------------------------
    struct VoteInfo {
        address player;  // Address of playerr
        bytes1 letter;   // Letter player voted for
    }

    enum GameResult {
        WON,          // The players guessed the word correctly
        LOST,         // The players used up all wrong guesses
        CANCELLED     // The game was abandoned or invalidated
    }

    // -----------------------------------------
    // Global variables
    // -----------------------------------------
    Game[MAX_GAMES] private games;
    mapping(string => uint8) private getGameIndex;
    uint8 public numOfActivegames = 0;


    // -----------------------------------------
    // Modifiers
    // -----------------------------------------
    modifier gameExists(string memory gameID) {
        require(
            getGameIndex[gameID] != 0,
            "Games is not active"
        );
        _;
    }

    modifier isPlayer(string memory gameID) {
        require(
            games[getGameIndex[gameID] - 1].isPlayer[msg.sender],
            "You are not a player of this game"
        );
        _;
    }

    // -----------------------------------------
    // Events
    // -----------------------------------------
    event GameCreated(string indexed gameID, uint8 numOfPlayers);
    event GameEnded(string indexed gameID, GameResult result, string solution);
    event PlayerJoined(string indexed gameID, address indexed player);
    event PlayerLeft(string indexed gameID, address indexed player);
    event VoteRegistered(string gameID, address indexed player, bytes1 letter);
    event VoteUnregistered(string gameID, address indexed player, bytes1 letter);
    event VoteStarted(string indexed gameID);
    event VoteEnded(string indexed gameID, bytes1 chosenLetter, string maskedWord, bool error);

    // -----------------------------------------
    // Public / External Functions
    // -----------------------------------------

    /**
     * @notice Create a new game, if there is space in the games array.
     * @param _gameID Identifier for the game.
     * @param _numOfPlayers The maximum number of players > 0, <= MAX_PLAYERS.
     */
    function createGame(
        string memory _gameID,
        uint8 _numOfPlayers
    ) external {
        // Requirements
        require(
            bytes(_gameID).length > 0,
            "The game ID cannot be empty"
        );
        require(
            getGameIndex[_gameID] == 0,
            "A game with the chosen ID already exists"
        );
        require(
            _numOfPlayers > 0 && _numOfPlayers <= MAX_PLAYERS,
            "At least one player required and at most MAX_PLAYERS allowed"
        );
        uint8 gameIndex = _allocateGame();
        require(
            gameIndex > 0,
            "No free game slot available"
        );

        // Init game 
        Game storage game = games[gameIndex - 1];
        game.gameID = _gameID;
        game.creator = msg.sender;
        game.maxPlayers = _numOfPlayers;
        uint256 randomNum = uint256(
            keccak256(
                abi.encodePacked(block.timestamp, msg.sender)
            )
        );
        game.hiddenWord = WORDS[randomNum % WORDS.length];
        game.revealedLetters = new bool[](bytes(game.hiddenWord).length);
        game.lastActionTimestamp = block.timestamp;
        getGameIndex[_gameID] = gameIndex;
        emit GameCreated(_gameID, _numOfPlayers);
        _addPlayerToGame(game, msg.sender);
    }

    /**
     * @notice Deletes an existing game.
     * @param _gameID Identifier for the game.
     */
    function deleteGame(string memory _gameID) external gameExists(_gameID) {
        Game storage game = games[getGameIndex[_gameID] - 1];
        require(
            game.creator == msg.sender || game.creator == address(0),
            "Only game creator can delete the game"
        );

        _endGame(game, GameResult.CANCELLED);
    }

    /**
     * @notice Join an active game.
     * @param _gameID Identifier for the game.
     */
    function joinGame(string memory _gameID) external gameExists(_gameID) {
        Game storage game = games[getGameIndex[_gameID] - 1];
        require(
            !game.isPlayer[msg.sender],
            "Already in the game"
        );
        require(
            game.currentPlayers < game.maxPlayers,
            "No more players slots available"
        );

        game.isPlayer[msg.sender] = true;
        emit PlayerJoined(_gameID, msg.sender);
    }

    /**
     * @notice Leave the game at any time while its active.
     * @param _gameID Identifier for the game.
     */
    function leaveGame(string memory _gameID) external gameExists(_gameID) isPlayer(_gameID) {
        Game storage game = games[getGameIndex[_gameID] - 1];

        // Remove player
        _removePlayerFromGame(game, msg.sender);

        // If no players are left, end the game
        if (game.currentPlayers == 0) {
            _endGame(game, GameResult.CANCELLED);
        }
    }

    /**
     * @notice Vote for a letter in the hangman game.
     * @param _gameID Identifier for the game.
     * @param _vote Letter to vote for.
     */
    function voteForLetter(string memory _gameID, string memory _vote) external gameExists(_gameID) isPlayer(_gameID) {
        bytes1 letter = bytes(_vote)[0];
        Game storage game = games[getGameIndex[_gameID] - 1];
        Vote storage vote = game.vote;
        require(
            vote.playerVotes[msg.sender] == 0,
            "You already voted"
        );
        bool uppercase = letter >= bytes1("A") && letter <= bytes1("Z");
        require(
            uppercase || (letter >= bytes1("a") && letter <= bytes1("z")),
            "Letter must be in A-Z or a-z"
        );
        // Convert upper to lowercase
        if (uppercase) {
            letter = bytes1(uint8(letter) - 32);
        }
        require(
            !game.guessedLetters[letter],
            "Letter has already been guessed"
        );

        _registerVote(game.gameID, vote, msg.sender, letter);
       game.lastActionTimestamp = block.timestamp;

        // End vote if duration has elapsed or all players have voted
        if (block.timestamp - vote.voteStartTimestamp > VOTING_DURATION ||
            vote.voteCount == game.currentPlayers) {
            _endVote(game);
        }
    }

    /**
     * @notice End a vote in case some players are not voting
     * @param _gameID Identifier for the game.
     */
    function endVote(string memory _gameID) external gameExists(_gameID) {
        Game storage game = games[getGameIndex[_gameID] - 1];
        Vote storage vote = game.vote;
        require(
            vote.votingActive,
            "No active vote"
        );
        require(
            block.timestamp - vote.voteStartTimestamp > VOTING_DURATION,
            "Vote duration has not elapsed"
        );
        _endVote(game);
    }

    // -----------------------------------------
    // Public getter functions
    // -----------------------------------------

    function getActiveGameIDs() external view returns (string[] memory) {

        if (numOfActivegames == 0) return new string[](0);

        // Create an array to store active game IDs
        string[] memory activeGames = new string[](numOfActivegames);
        uint8 index;

        // Populate the active game IDs array
        for (uint8 i = 0; i < MAX_GAMES; i++) {
            if (bytes(games[i].gameID).length > 0) {
                activeGames[index] = games[i].gameID;
                index++;
            }
        }

        return activeGames;
    }

    function getGameByID(string memory _gameID)
        external gameExists(_gameID)
        view
        returns (
            address creator,
            uint8 maxPlayers,
            uint8 currentPlayers,
            string memory hiddenWord,
            bool[] memory revealedLetters,
            uint8 guessCount,
            uint256 lastActionTimestamp,
            bool activeVote,
            uint8 voteCount,
            uint256 voteStartTimestamp,
            VoteInfo[] memory
        )
    {
        for (uint8 i = 0; i < MAX_GAMES; i++) {
            if (
                keccak256(bytes(games[i].gameID)) == keccak256(bytes(_gameID))
            ) {
                Game storage game = games[i];
                uint8 count = game.vote.voteCount;
                VoteInfo[] memory votes;

                if (game.vote.votingActive && count > 0) {
                    votes = new VoteInfo[](count);
                    for (i = 0; i < count; i++) {
                        votes[i].player = game.vote.playersVoted[i];
                        votes[i].letter = game.vote.playerVotes[votes[i].player];
                    }
                } else {
                    votes = new VoteInfo[](0);
                }

                // Return all required fields
                return (
                    game.creator,
                    game.maxPlayers,
                    game.currentPlayers,
                    game.hiddenWord,
                    game.revealedLetters,
                    game.guessCount,
                    game.lastActionTimestamp,
                    game.vote.votingActive,
                    game.vote.voteCount,
                    game.vote.voteStartTimestamp,
                    votes
                );
            }
        }

        revert("Game not found");
    }

    // -----------------------------------------
    // Maintenance (Marking stale games, etc.)
    // -----------------------------------------

    /**
     * @notice Allocate a new game in the games array (Returns 0 if no spot is free)
     */
    function _allocateGame() private returns (uint8) {
        for (uint8 i = 0; i < games.length; i++) {
            Game storage game = games[i];
            if (getGameIndex[game.gameID] == 0) {
                numOfActivegames++;
                return i + 1;
            }
            // Cancel game that has been idle for too long.
            if (block.timestamp - game.lastActionTimestamp > INACTIVITY_THRESHOLD) {
                _endGame(game, GameResult.CANCELLED);
                numOfActivegames++;
                return i + 1;
            }
        }
        return 0;
    }
    function _endGame(Game storage game, GameResult result) private {
        emit GameEnded(game.gameID, result, game.hiddenWord);
        uint8 index = getGameIndex[game.gameID];
        delete getGameIndex[game.gameID];
        delete games[index - 1];
        numOfActivegames--;
    }

    function _registerVote(string storage gameID, Vote storage vote, address player, bytes1 letter) private {
        vote.playersVoted[vote.voteCount] = player;
        vote.playerVotes[player] = letter;
        vote.letterCounts[letter] += 1;
        vote.voteCount += 1;
        if (!vote.votingActive) {
            vote.votingActive = true;
            vote.voteStartTimestamp = block.timestamp;
            emit VoteStarted(gameID);
        }
        emit VoteRegistered(gameID, player, letter);
    }

    function _unregisterVote(string storage gameID, Vote storage vote, address player) private {
        bytes1 letter = vote.playerVotes[player];
        vote.playerVotes[player] = 0;
        bool move = false;
        for (uint i = 0; i < vote.voteCount; i++) {
            if (vote.playersVoted[i] == player) {
                vote.playersVoted[i] = address(0);
                move = true;
                continue;
            } else if (move) {
                address tmp = vote.playersVoted[i-1];
                vote.playersVoted[i-1] = vote.playersVoted[i];
                vote.playersVoted[i] = tmp;
            }
        }
        vote.voteCount -= 1;
        emit VoteUnregistered(gameID, player, letter);
    }

    function _endVote(Game storage game) private {
        Vote storage vote = game.vote;
        bytes1 voted_letter = 0;
        bool done = true;
        bool hit = false;
        uint8 max = 0;

        // Determine letter that won vote
        for (uint i = 0; i < vote.voteCount; i++) {
            address player = vote.playersVoted[i];
            bytes1 letter = vote.playerVotes[player];
            uint8 count = vote.letterCounts[letter];
            delete vote.playerVotes[player];

            if (count > max) {
                voted_letter = letter;
            }
        }

        bytes memory maskedWord = bytes(game.hiddenWord); 
        for (uint i = 0; i < bytes(maskedWord).length; i++) {
            if (maskedWord[i] == voted_letter) {
                game.guessedLetters[voted_letter] = true;
                game.revealedLetters[i] = true;
                hit = true;
            } else if (!game.revealedLetters[i]) {
                maskedWord[i] = "_";
                done = false;
            }
        }

        delete game.vote;
        emit VoteEnded(game.gameID, voted_letter, string(maskedWord), !hit);
        if (!hit) {
            game.guessCount += 1;
            if (game.guessCount == MAX_GUESSES) {
                _endGame(game, GameResult.LOST);
            }
        } else if (done) {
            _endGame(game, GameResult.WON);
        }
    }

    function _addPlayerToGame(Game storage game, address player) private {
        game.isPlayer[player] = true;
        game.currentPlayers += 1;
    }

    function _removePlayerFromGame(Game storage game, address player) private {
        game.isPlayer[player] = false;
        game.currentPlayers -= 1;

        // Remove vote if present
        Vote storage vote = game.vote;
        if (game.currentPlayers > 0 && vote.votingActive && vote.playerVotes[player] != 0) {
            _unregisterVote(game.gameID, vote, player);
        }

        if (game.creator == player) {
            game.creator = address(0);
        }
        emit PlayerLeft(game.gameID, player);
    }
}
