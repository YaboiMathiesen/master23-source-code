LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.std_logic_arith.all;
USE ieee.std_logic_unsigned.all;


entity scrubber is
    generic(
	   coeff_width : integer := 8; -- Width of the coefficients found in block ram.(Any change in this value must be done in Blockram)
	   coeff_addr_width : integer := 8; -- Address width, any change here must be reflected in Blockram
	   command_width : integer := 8; -- Tweak after need
	   status_width : integer := 8; -- Tweak after need
	   message_word_length : integer := 32 -- Coeff_width+addr_width+command_width + status width
	   -- SPI controller of GR716a only supports a max 32 bit word length
    );
    port(
	   -- Common signals
	   clk	: in std_logic;
	   reset_n : in std_logic;
	   
	   -- Coefficient/Blockram access
	   coeff_write_data : out std_logic_vector(coeff_width - 1 downto 0);
	   coeff_write_en : out std_logic;
	   coeff_write_addr : out std_logic_vector(coeff_addr_width-1 downto 0);
	   coeff_read_req_scrubber : out std_logic;
	   coeff_read_data_scrubber : in std_logic_vector(coeff_width - 1 downto 0);
	   coeff_read_addr_scrubber : out std_logic_vector(coeff_addr_width - 1 downto 0);
	   coeff_read_data_rdy_scrubber : in std_logic;
	   
	
	   -- To communication(SPI slave) module
	   busy : in std_logic;
	   tx_load_en : buffer std_logic; 
	   tx_load_data : out std_logic_vector(message_word_length - 1 downto 0);
	   rx_req : out std_logic;
	   rx_data : in std_logic_vector(message_word_length - 1 downto 0);
	   rx_rdy : in std_logic
	   	   
	   
    );
end scrubber;

architecture behavioral of scrubber is
    -- Constants to make accessing of data more structured and variyng with generics both.
    constant RX_COMMAND_START : integer := message_word_length-1;
    constant RX_COMMAND_END   : integer := message_word_length-command_width;
    constant RX_ADDRESS_START : integer := message_word_length-command_width-1;
    constant RX_ADDRESS_END : integer := message_word_length-command_width-coeff_addr_width;
    constant RX_COEFF_START  : integer := message_word_length-command_width-coeff_addr_width-1;
    constant RX_COEFF_END : integer := message_word_length-command_width-coeff_addr_width-coeff_width;
    constant TX_STATUS_WIDTH : integer := message_word_length-command_width-coeff_addr_width-coeff_width; -- The same as RX_COEFF_END;
    
    signal tx_message : std_logic_vector(message_word_length-1 downto 0) := (others => '0'); -- Message we want to send
    signal command : std_logic_vector(command_width-1 downto 0) := (others => '0'); -- Command of received message
    signal rx_coefficient : std_logic_vector(coeff_width-1 downto 0) := (others => '0'); -- Coefficient of received message;
	signal mem_coefficient : std_logic_vector(coeff_width-1 downto 0) := (others => '0');
    
    -- TMR for the received message, allows us to send back the message as ACK without trouble
    signal message_register0 : std_logic_vector(message_word_length-1 downto 0) := (others => '0');
    signal message_register1 : std_logic_vector(message_word_length-1 downto 0) := (others => '0');
    signal message_register2 : std_logic_vector(message_word_length-1 downto 0) := (others => '0');
    
    -- For checking validity
    signal rx_address_val : unsigned(coeff_addr_width-1 downto 0) := (others => '0');
    signal rx_coefficient_val : unsigned(coeff_addr_width-1 downto 0) := (others => '0');
	
	type rx_states is (IDLE,RX_WAIT,FETCH,DECODE,VERIFY,MEM_READ_START,MEM_READ_WAIT,MEM_READ_CHECK,MEM_WRITE,ILLEGAL,ERROR);
	signal rx_state : rx_states := IDLE;
	signal rx_expt_state : rx_states := IDLE;
	
	type tx_states is (IDLE,WAIT_BUSY,WAIT_RX,FINALIZE,SEND_MSG,ERROR);
	signal tx_state : tx_states := IDLE;
	signal tx_expt_state : tx_states := IDLE;
	
    signal tx_delay : unsigned(3 downto 0) := "0000"; -- For waiting for stable signal

	-- Attribute "One-hot" to state machine encoding 
	attribute fsm_encoding : string;
    attribute fsm_encoding of rx_state : signal is "one_hot";
    attribute fsm_encoding of tx_state : signal is "one_hot";
	attribute fsm_encoding of rx_expt_state : signal is "one_hot";
	attribute fsm_encoding of tx_expt_state : signal is "one_hot";
    
    -- Status reg(Sent to GR716)
    signal status_reg   : std_logic_vector(TX_STATUS_WIDTH-1 downto 0) := (others => '0');
    
	-- Latching ERROR trigger for edge detection
    signal ERROR_trigger_r : std_logic := '0';
		
	-- Attribute to keep signals
    -- attribute keep : string;
    -- attribute keep of message_register0 : signal is "true";
    -- ...
    attribute keep : string;
    attribute keep of message_register0 : signal is "true";
	attribute keep of message_register1 : signal is "true";
	attribute keep of message_register2 : signal is "true";
    attribute keep of tx_message : signal is "true";
    attribute keep of command : signal is "true";
    attribute keep of rx_coefficient : signal is "true";
    attribute keep of mem_coefficient : signal is "true";
    attribute keep of rx_address_val : signal is "true";
    attribute keep of rx_coefficient_val : signal is "true";
    attribute keep of rx_state : signal is "true";
    attribute keep of tx_state : signal is "true";
    attribute keep of status_reg : signal is "true";
    attribute keep of ERROR_trigger_r : signal is "true";
    attribute keep of tx_expt_state : signal is "true";
    attribute keep of rx_expt_state : signal is "true";

begin

	-- *********************************************************
	-- Handles receiving of SPI messages, DECODEs, validity check
	-- and performs read and write accesses to the blockram
	-- *********************************************************
	process(reset_n, clk)
	begin
		if(reset_n = '0') then
			-- Reset signals
			rx_state <= IDLE;
			rx_expt_state <= IDLE;
			rx_req <= '0';
			message_register0 <= (others => '0');
			message_register1 <= (others => '0');
			message_register2 <= (others => '0');
			coeff_read_addr_scrubber <= (others => '0');
			rx_coefficient <= (others => '0');
			coeff_read_req_scrubber <= '0';
			mem_coefficient <= (others => '0');
			coeff_write_addr <= (others => '0');
			coeff_write_data <= (others => '0');
			coeff_write_en <= '0';
		elsif(rising_edge(clk)) then

			case(rx_state) is
				when IDLE =>
					-- **********************************************
					-- Wait for SPI module to have data available for us
					-- Set rx_req high, go to next state(data should be available then)
					-- **********************************************
					if(rx_rdy = '1') then -- Falling edge detector
						rx_req <= '1';
						rx_state <= RX_WAIT;
						rx_expt_state <= RX_WAIT;
						
					else
					   rx_state <= IDLE;
					   rx_expt_state <= IDLE;
					end if;
					
				when RX_WAIT => 
				    -- **********************************************
				    -- Wait for RX line to be available before we read
				    -- Can add a longer delay here if necessary
				    -- **********************************************
				    rx_state <= FETCH;
				    rx_expt_state <= FETCH;
				    coeff_write_en <= '0';
				    message_register0 <= rx_data;
					message_register1 <= rx_data;
					message_register2 <= rx_data;
					
					
				when FETCH =>
					-- **********************************************
					-- rx_data should be available
					-- Data is available in messge_registers
					-- **********************************************
					rx_req <= '0';
					rx_address_val <= unsigned(rx_data(RX_ADDRESS_START downto RX_ADDRESS_END));
					rx_coefficient_val <= unsigned(rx_data(RX_COEFF_START downto RX_COEFF_END));
					rx_state <= VERIFY;
					rx_expt_state <= VERIFY;

					
				when VERIFY =>
					-- **********************************************
					-- No point in performing operations with message if
					-- the data we have been sent is corrupted. Check address
					-- and data field for valid data before proceeding
					-- Legal address range 0x00 to 0x0F 
					-- Legal data range 0x00 to 0x20;
					-- These values reflect the contents of the blockram
					-- **********************************************
					if(rx_address_val > 16) then
						rx_state <= ILLEGAL;
						rx_expt_state <= ILLEGAL;
					elsif(rx_coefficient_val > 32) then
						rx_state <= ILLEGAL;
						rx_expt_state <= ILLEGAL;
					else
						command <= message_register0(RX_COMMAND_START downto RX_COMMAND_END);
						rx_state <= DECODE;
						rx_expt_state <= DECODE;
					end if;

					
				when DECODE =>
					-- **********************************************
					-- check validity and DECODE command to determine next state
					-- **********************************************
					case(command) is
						when "00000001" =>
							rx_state <= MEM_WRITE;
							rx_expt_state <= MEM_WRITE;
						when "00000100" =>
							rx_state <= MEM_READ_START;
							rx_expt_state <= MEM_READ_START;
						when others =>
							rx_state <= ILLEGAL;
							rx_expt_state <= ILLEGAL;
					end case;
						
				when MEM_READ_START =>
					-- **********************************************
					-- Put in a read request at the coefficient memory
					-- FETCH the coefficient from received SPI message
					-- Optionally use TMR voting, but this is a 2-3
					-- clock cycles window
					-- **********************************************
					coeff_read_addr_scrubber <= message_register0(RX_ADDRESS_START downto RX_ADDRESS_END); -- FETCH addr
					rx_coefficient <= message_register0(RX_COEFF_START downto RX_COEFF_END); -- Already read earlier
					coeff_read_req_scrubber <= '1';
					rx_state <= MEM_READ_WAIT;
					rx_expt_state <= MEM_READ_WAIT;

				when MEM_READ_WAIT =>
					-- **********************************************
					-- Wait for mem read request has been handled and data
					-- is available. End request.
					-- **********************************************
					if(coeff_read_data_rdy_scrubber = '1') then
						coeff_read_req_scrubber <= '0';
						mem_coefficient <= coeff_read_data_scrubber;
						rx_state <= MEM_READ_CHECK;
						rx_expt_state <= MEM_READ_CHECK;
					else
					   rx_state <= MEM_READ_WAIT;
					   rx_expt_state <= MEM_READ_WAIT;
					end if;

					
				when MEM_READ_CHECK => 
					-- **********************************************
					-- Compare received coeffcient with one from memory
					-- If mismatch we write(We are only module with write access9
					-- else we are done with this message. Return to IDLE
					-- **********************************************
					if(rx_coefficient = mem_coefficient) then
						rx_state <= IDLE;
						rx_expt_state <= IDLE;
					else
						rx_state <= MEM_WRITE;
						rx_expt_state <= MEM_WRITE;
					end if;
			
				
				when MEM_WRITE => 
					-- **********************************************
					-- Put in a write request to override contents of blockram
					-- The blockram is configured to handle this request right
					-- away with no conflict.(At least it should be)
					-- **********************************************
					coeff_write_addr <= message_register0(RX_ADDRESS_START downto RX_ADDRESS_END);
					coeff_write_data <= rx_coefficient;
					coeff_write_en <= '1';
					rx_state <= IDLE;
					rx_expt_state <= IDLE;
					

				when ILLEGAL =>
					-- **********************************************
					-- We arrive here due to invalid message contents
					-- We discard the message by going back to IDLE
					-- **********************************************
					rx_state <= IDLE;
					rx_expt_state <= IDLE;
							
				when ERROR =>
					rx_state <= rx_expt_state;
					
				when others =>
					-- Recovery state
					rx_state <= rx_expt_state;
			end case;	
		end if;
	end process;
	
	
	-- **********************************************
	-- Transmit state machine
	-- **********************************************
	process(reset_n,clk)
	begin
		if(reset_n = '0') then
			tx_load_data <= (others => '0');
			tx_load_en <= '0';
			tx_state <= IDLE;
			tx_expt_state <= IDLE;
			status_reg <= (others => '0');
			tx_message <= (others => '0');
			tx_delay <= "0000";
		elsif(rising_edge(clk)) then
		
			case(tx_state) is
				when IDLE =>
					-- **********************************************
					-- The spi slave starts non-busy. We have nothing
					-- special to send it, so we wait for a rising edge of busy
					-- **********************************************					
					if(busy = '1') then -- Now we dont listen on during messages, can be changed by busy = '1' as condition.
						tx_state <= WAIT_BUSY;
						tx_expt_state <= WAIT_BUSY;
						status_reg <= (others => '0');
						tx_load_en <= '0';
			        else
			            tx_state <= IDLE;
			            tx_expt_state <= IDLE;
					end if;
				
				when WAIT_BUSY =>
						-- **********************************************
						-- We have to wait for the message to be over, so
						-- we can pass along what is to be transmitted next
						-- **********************************************
						if(busy = '0') then
							tx_state <= WAIT_RX;
							tx_expt_state <= WAIT_RX;
						else
							tx_state <= WAIT_BUSY;
							tx_expt_state <= WAIT_BUSY;
						end if;
						
				when WAIT_RX =>
				        -- **********************************************
				        -- Message register must have contents we want before we
				        -- write to spi module
				        -- **********************************************
				        if(tx_delay = 5) then
				            tx_delay <= "0000";
				            tx_state <= FINALIZE;
				            tx_expt_state <= FINALIZE;
				        else
				            tx_delay <= tx_delay + 1;
				            tx_state <= WAIT_RX;
				            tx_expt_state <= WAIT_RX;
				        end if;				        
						
				when FINALIZE =>
						-- **********************************************
						-- We put together the final message, so it is ready 
						-- to be put on the tx line.
						-- **********************************************
						tx_message <= ((message_register0(31 downto 8) and message_register1(31 downto 8)) or (message_register0(31 downto 8) and message_register2(31 downto 8)) or (message_register1(31 downto 8) and message_register2(31 downto 8))) & status_reg; --X"000000" & status_reg;
						tx_state <= SEND_MSG;
						tx_expt_state <= SEND_MSG;
				       	
				when SEND_MSG =>
					-- **********************************************
					-- Send msg to SPI module for transfer
					-- Return to IDLE
					-- **********************************************
					tx_load_data <= tx_message;
					tx_load_en <= '1';
					tx_state <= IDLE;
					tx_expt_state <= IDLE;
	
				when ERROR =>
					tx_state <= tx_expt_state;
					
				when others =>
					-- **********************************************
					-- Recovery
					-- **********************************************
				    tx_state <= tx_expt_state;
				
			end case;
		end if;
	end process;
    
end behavioral;