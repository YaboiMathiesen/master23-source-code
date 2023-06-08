-- Instantiates 3 blocks of RAM
-- Manages a tristate-buffer type thing to make sure read signals from filter and subsystem do not overlap and crash
-- Performs the voting?


library IEEE;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all; -- Might not need all these, but what cost do they have?

entity coefficient_memory is
    generic(
        coefficient_width : integer := 8;
        addr_width : integer := 8
    );
    port(
        clk : in std_logic; -- Might not be necessary
        reset_n : in std_logic;
        
        coeff_read_req_scrubber : in std_logic;     -- Handshake signal from scrubber
        coeff_read_req_filter   : in std_logic;     -- Handshake from filter.
        coeff_read_data_rdy_scrubber : out std_logic; -- Lets scrubber now it can read
        coeff_read_data_rdy_filter   : out std_logic; 
        
        coeff_write_addr  : in std_logic_vector(addr_width-1 downto 0);
        coeff_write_en : in std_logic;
        coeff_write_data  : in std_logic_vector(coefficient_width -1 downto 0);
        coeff_read_addr_filter   : in std_logic_vector(addr_width-1 downto 0);
        coeff_read_addr_scrubber   : in std_logic_vector(addr_width-1 downto 0);
        coeff_read_data_scrubber   : out std_logic_vector(coefficient_width - 1 downto 0);
        coeff_read_data_filter    : out std_logic_vector(coefficient_width-1 downto 0)
        
    );
end coefficient_memory;

architecture behavioral of coefficient_memory is
    signal bram_we : std_logic_vector(0 downto 0) := (others => '0');
    
    signal bram_read_addr : std_logic_vector(addr_width-1 downto 0) := (others => '0');
    signal bram_read_enable : std_logic := '0';
    signal bram_read_block0 : std_logic_vector(coefficient_width-1 downto 0) := (others => '0');
    signal bram_read_block1 : std_logic_vector(coefficient_width-1 downto 0) := (others => '0');
    signal bram_read_block2 : std_logic_vector(coefficient_width-1 downto 0) := (others => '0');
    
    signal minorityVoteOutput   : std_logic_vector(coefficient_width -1 downto 0) := (others => '0');
    signal minorityVote    : std_logic := '0';
	
	signal majorityVoteOutput : std_logic_vector(coefficient_width-1 downto 0) := (others => '0');
	signal majorityVote : std_logic := '0';
    
    signal counter : unsigned(3 downto 0) := (others => '0');
    
    type states is (idle,start_read_scrubber,wait_data_rdy_scrubber,wait_vote_scrubber,pass_to_scrubber,req_end_scrubber,start_read_filter,wait_data_rdy_filter,wait_vote_filter,pass_to_filter,req_end_filter,ERROR); -- Operations associated with writing will be done asynchronously to reading.
	signal state : states := idle;
	signal expt_state : states := idle;
	
	
    -- State encoding
    attribute fsm_encoding : string;
    attribute fsm_encoding of state : signal is "one_hot";
    attribute fsm_encoding of expt_state : signal is "one_hot";
	
	-- Attribute keep
	attribute keep : string;
    attribute keep of bram_we : signal is "true";
    attribute keep of bram_read_addr : signal is "true";
    attribute keep of bram_read_enable : signal is "true";
    attribute keep of bram_read_block0 : signal is "true";
    attribute keep of bram_read_block1 : signal is "true";
    attribute keep of bram_read_block2 : signal is "true";
    
    attribute keep of minorityVoteOutput : signal is "true";
    attribute keep of minorityVote : signal is "true";
    
    attribute keep of majorityVoteOutput : signal is "true";
    attribute keep of majorityVote : signal is "true";
    attribute keep of counter : signal is "true";
    attribute keep of state : signal is "true";
    attribute keep of expt_state : signal is "true";
    attribute keep of error_trigger_r  : signal is "true";
    
    
begin 
    coeff_ram_block_0 : entity work.blockram_wrapper
        port map(
            BRAM_PORTA_0_addr => coeff_write_addr,
            BRAM_PORTA_0_clk => clk,
            BRAM_PORTA_0_din => coeff_write_data,
            BRAM_PORTA_0_en => coeff_write_en,
            BRAM_PORTA_0_we => bram_we,
            BRAM_PORTB_0_addr => bram_read_addr,
            BRAM_PORTB_0_clk => clk, -- common clock
            BRAM_PORTB_0_dout => bram_read_block0,
            BRAM_PORTB_0_en => bram_read_enable
        );
        
    coeff_ram_block_1 : entity work.blockram_wrapper
        port map(
            BRAM_PORTA_0_addr => coeff_write_addr,
            BRAM_PORTA_0_clk => clk,
            BRAM_PORTA_0_din => coeff_write_data,
            BRAM_PORTA_0_en => coeff_write_en,
            BRAM_PORTA_0_we => bram_we,
            BRAM_PORTB_0_addr => bram_read_addr,
            BRAM_PORTB_0_clk => clk, -- common clock
            BRAM_PORTB_0_dout => bram_read_block1,
            BRAM_PORTB_0_en => bram_read_enable
        );
    
    coeff_ram_block_2 : entity work.blockram_wrapper
        port map(
            BRAM_PORTA_0_addr => coeff_write_addr,
            BRAM_PORTA_0_clk => clk,
            BRAM_PORTA_0_din => coeff_write_data,
            BRAM_PORTA_0_en => coeff_write_en,
            BRAM_PORTA_0_we => bram_we,
            BRAM_PORTB_0_addr => bram_read_addr,
            BRAM_PORTB_0_clk => clk, -- common clock
            BRAM_PORTB_0_dout => bram_read_block2,
            BRAM_PORTB_0_en => bram_read_enable
        );
     
    -- No idea what we is, why have a "write enable" when you already have enable there??
    process(reset_n,clk) begin
        if(reset_n = '0') then
            bram_we <= "0";
        elsif(rising_edge(clk)) then
            if(coeff_write_en = '1') then
                bram_we <= "1";
            else
                bram_we <= "0";
            end if;
        end if;
    end process;
     
    
     
    -- Minority voting
    process(reset_n,clk) begin
		if(reset_n = '0') then
			minorityVoteOutput <= (others => '0');
		elsif(rising_edge(clk)) then
			if(minorityVote = '1') then
				for i in 0 to coefficient_width-1 loop
					minorityVoteOutput(i) <= ((not bram_read_block0(i)) and (not bram_read_block1(i)) and (bram_read_block2(i))) or ((not bram_read_block0(i)) and (bram_read_block1(i)) and (not bram_read_block2(i))) or ((bram_read_block0(i)) and (not bram_read_block1(i)) and (not bram_read_block2(i))) or ((bram_read_block0(i)) and (bram_read_block1(i)) and (bram_read_block2(i)));
				end loop;
			end if;
		end if;
    end process;
	 
	-- Majority voting
    process(reset_n,clk) begin
		if(reset_n = '0') then
			majorityVoteOutput <= (others => '0');
		elsif(rising_edge(clk)) then
			if(majorityVote = '1') then
				majorityVoteOutput <= (((bram_read_block0 and bram_read_block1) or (bram_read_block0 and bram_read_block2)) or (bram_read_block1 and bram_read_block2));
			end if;
		end if;	
	end process;
	
     -- State machine for memory read access
	process(reset_n,clk) 
	begin
		if(reset_n = '0') then
			state <= idle;
			expt_state <= idle;
			bram_read_addr <= (others => '0');
			bram_read_enable <= '0';
			coeff_read_data_scrubber <= (others => '0');
			coeff_read_data_filter <= (others => '0');
			coeff_read_data_rdy_filter <= '0';
			coeff_read_data_rdy_scrubber <= '0';
			majorityVote <= '0';
			minorityVote <= '0';
			counter <= (others => '0');
		elsif(rising_edge(clk)) then

			case(state) is
				when idle =>
					-- *******************************************************
					-- We wait for requests from either scrubber or filter
					-- We prioritize the scrubber since it makes less requests
					-- *******************************************************
					if(coeff_read_req_scrubber = '1' and coeff_read_req_filter = '1') then
						state <= start_read_scrubber;
						expt_state <= start_read_scrubber;
					elsif(coeff_read_req_scrubber = '1' and coeff_read_req_filter = '0') then
						state <= start_read_scrubber;
						expt_state <= start_read_scrubber;
					elsif(coeff_read_req_scrubber = '0' and coeff_read_req_filter = '1') then
						state <= start_read_filter;
						expt_state <= start_read_filter;
					else
						state <= idle;
						expt_state <= idle;
					end if;
					
					
				when start_read_scrubber =>
					-- *******************************************************
					-- Put in a read request with block ram, data is available
					-- roughly 2-3 clock cycles after
					-- *******************************************************
					bram_read_addr <= coeff_read_addr_scrubber;
					bram_read_enable <= '1';
					state <= wait_data_rdy_scrubber;
					expt_state <= wait_data_rdy_scrubber;
					
								
				when wait_data_rdy_scrubber =>
					-- *******************************************************
					-- Use a counter to keep track of cycles until we can read
					-- *******************************************************
					if(counter = 3) then
						state <= wait_vote_scrubber;
						expt_state <= wait_vote_scrubber;
						minorityVote <= '1';
						counter <= (others => '0');
					else
						counter <= counter + 1;
						state <= wait_data_rdy_scrubber;
						expt_state <= wait_data_rdy_scrubber;
					end if;
									
					
				when wait_vote_scrubber=>
					-- *******************************************************
					-- Perform minority voting, give it time to finish
					-- Add counter if necessary
					-- *******************************************************
					
					state <= pass_to_scrubber;
					expt_state <= pass_to_scrubber;
					
					
					
				when pass_to_scrubber =>
					-- *******************************************************
					-- Make data available to scrubber
					-- We could have a following state to wait for it to read.
					-- *******************************************************
					coeff_read_data_scrubber <= minorityVoteOutput;
                    coeff_read_data_rdy_scrubber <= '1';
					state <= req_end_scrubber;
					expt_state <= req_end_scrubber;
					
					
					
				when req_end_scrubber =>
					-- *******************************************************
					-- Wait for falling edge of the request, signaling end of
					-- transaction. Return to idle
					-- *******************************************************
					if(coeff_read_req_scrubber = '0') then
						state <= idle;
						expt_state <= idle;
						coeff_read_data_rdy_scrubber <= '0';
					else
					   state <= req_end_scrubber;
					   expt_state <= req_end_scrubber;
					end if;
					
					
					
				when start_read_filter =>
					bram_read_addr <= coeff_read_addr_filter;
					bram_read_enable <= '1';
					state <= wait_data_rdy_filter;
					expt_state <= wait_data_rdy_filter;
					
					
					
				when wait_data_rdy_filter =>
					if(counter = 3) then
						majorityVote <= '1';
						counter <= (others => '0');
						state <= wait_vote_filter;	
						expt_state <= wait_vote_filter;				
					else
					   state <= wait_data_rdy_filter;
					   expt_state <= wait_data_rdy_filter;
					   counter <= counter + 1;
					end if;
					
					
					
				when wait_vote_filter =>
					state <= pass_to_filter;
					expt_state <= pass_to_filter;
					
					
					
				when pass_to_filter =>
					coeff_read_data_filter <= majorityVoteOutput;
					coeff_read_data_rdy_filter <= '1';
					state <= req_end_filter;
					expt_state <= req_end_filter;
					
					
					
				when req_end_filter =>
					if(coeff_read_req_filter = '0') then
						state <= idle;
						expt_state <= idle;
						coeff_read_data_rdy_filter <= '0';
					else
					   state <= req_end_filter;
					   expt_state <= req_end_filter;
					end if;
					
				when ERROR =>
					--Recovery
					state <= expt_state;
				when others =>
				    state <= expt_state;

			end case;

		end if;
	end process;
     
     
end behavioral;