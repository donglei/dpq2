module dpq2.answer;

@trusted:

public import dpq2.query;

import derelict.pq.pq;

import core.vararg;
import std.string: toStringz;
import std.exception;
import core.exception;
import std.traits;
import std.bitmanip: bigEndianToNative;
import std.datetime;
import std.uuid;
import std.typecons: Nullable;

// Supported PostgreSQL binary types
alias short   PGsmallint; /// smallint
alias int     PGinteger; /// integer
alias long    PGbigint; /// bigint
alias float   PGreal; /// real
alias double  PGdouble_precision; /// double precision
alias string  PGtext; /// text
alias const ubyte[] PGbytea; /// bytea
alias SysTime PGtime_stamp; /// time stamp with/without timezone
alias UUID    PGuuid; /// UUID

/// Result table's cell coordinates 
struct Coords
{
    size_t Row; /// Row
    size_t Col; /// Column
}

/// Answer
class Answer
{
    private const (PGresult*) res;

    nothrow invariant()
    {
        assert( res != null );
    }
        
    package this(PGresult* r) nothrow
    {
        res = r;
    }
    
    ~this()
    {
        if( res )
        {
            PQclear(res);
        }
        else
            assert( true, "double free!" );
    }
    
    package void checkAnswerForErrors() const
    {
        cast(void) enforceEx!OutOfMemoryError(res, "Can't write query result");
        if(!(status == ExecStatusType.PGRES_COMMAND_OK ||
             status == ExecStatusType.PGRES_TUPLES_OK))
        {
            throw new exception( exception.exceptionTypes.UNDEFINED_FIXME,
                resultErrorMessage~" ("~to!string(status)~")" );
        }
    }
    
    @property
    ExecStatusType status() const
    {
        return PQresultStatus(res);
    }

    /// Returns the command status tag from the SQL command that generated the PGresult
    /**
     * Commonly this is just the name of the command, but it might include 
     * additional data such as the number of rows processed. The caller should 
     * not free the result directly. It will be freed when the associated 
     * PGresult handle is passed to PQclear.
     */
    @property string cmdStatus() const
    {
        return to!string( PQcmdStatus(res) );
    }

    /// Returns row count
    @property size_t rowCount() const { return PQntuples(res); }

    /// Returns column count
    @property size_t columnCount() const { return PQnfields(res); }

    /// Returns column format
    valueFormat columnFormat( const size_t colNum ) const
    {
        assertCol( colNum );
        return PQfformat(res, cast(int)colNum);
    }
    
    /// Returns column Oid
    @property Oid OID( size_t colNum ) const
    {
        assertCol( colNum );
        return PQftype(res, cast(int)colNum);
    }
    
    /// Returns column number by field name
    size_t columnNum( string columnName ) const
    {    
        size_t n = PQfnumber(res, toStringz(columnName));
        if( n == -1 )
            throw new exception(exception.exceptionTypes.COLUMN_NOT_FOUND,
                                "Column '"~columnName~"' is not found");
        return n;
    }
    
    /// Returns pointer to row of cells
    Row opIndex(in size_t row) const
    {
        return const Row( this, row );
    }
    
    @property
    debug override string toString() const
    {
        return "Rows: "~to!string(rowCount)~" Columns: "~to!string(columnCount);
    }
    
    @property
    private string resultErrorMessage() const
    {
        return to!string( PQresultErrorMessage(res) );
    }
    
    private void assertCol( const size_t c ) const
    {
        enforce( c < columnCount, to!string(c)~" col is out of range 0.."~to!string(columnCount)~" of result cols" );
    }
    
    private void assertRow( const size_t r ) const
    {
        enforce( r < rowCount, to!string(r)~" row is out of range 0.."~to!string(rowCount)~" of result rows" );
    }
    
     private void assertCoords( const Coords c ) const
    {
        assertRow( c.Row );
        assertCol( c.Col );
    }    
    
    package size_t currRow;
    
    @property Row front(){ return this[currRow]; }
    @property void popFront(){ ++currRow; }
    @property bool empty(){ return currRow >= rowCount; }
}

const struct Row
{
    private const Answer answer;
    private immutable size_t row;
    
    this( const Answer answer, size_t row )
    {
        answer.assertRow( row );
        
        this.answer = answer;
        this.row = row;
    }
    
    /// Returns cell size
    @property
    size_t size( const size_t col ) const
    {
        answer.assertCol(col);
        return PQgetlength(answer.res, cast(int)row, cast(int)col);
    }
    
    /// Value NULL checking
    @property
    bool isNULL( const size_t col ) const
    {
        return PQgetisnull(answer.res, cast(int)row, cast(int)col) != 0;
    }
    
    Nullable!Value opIndex(in size_t col) const
    {
        answer.assertCoords( Coords( row, col ) );
        
        auto v = PQgetvalue(answer.res, cast(int)row, cast(int)col);
        auto s = size( col );
        
        Nullable!Value r;
        
        if(!isNULL(col))
            r = Value( v, s, answer.columnFormat( col ) );
        
        return r;
    }
    
    Nullable!Value opIndex(in string column) const
    {
        return opIndex(columnNum(column));
    }
    
    /// Returns column number by field name
    size_t columnNum( string columnName ) const
    {
        return answer.columnNum( columnName );
    }
    
    /// Returns column count
    @property size_t columnCount() const{ return answer.columnCount(); }
    
    @property
    debug string toString() const
    {
        return "Columns: "~to!string(columnCount);
    }
}

/// Link to the cell of the answer table
struct Value
{
    private ubyte[] value;
    private valueFormat format;
    
    this( const (ubyte)* value, size_t valueSize, valueFormat f )
    {
        this.value = cast(ubyte[]) value[0..valueSize];
        format = f;
    }
    
    this( const ubyte[] value )
    {
        this.value = cast(ubyte[]) value;
        format = valueFormat.BINARY;
    }

    /// Returns value as bytes from binary formatted field
    @property T as(T)() const
    if( is( T == const(ubyte[]) ) )
    {
        enforce( format == valueFormat.BINARY, "Format of the column is not binary" );
        return value;
    }

    /// Returns cell value as native string type
    @property T as(T)() const
    if(is(T == string))
    {
        return cast(const(char[])) value;
    }
    
    /// Returns cell value as native integer or decimal values
    ///
    /// Postgres type "numeric" is oversized and not supported by now
    @property T as(T)() const
    if( isNumeric!(T) )
    {
        enforce( format == valueFormat.BINARY, "Format of the column is not binary" );
        enforce( value.length == T.sizeof, "Value length isn't equal to type size" );
        
        ubyte[T.sizeof] s = value[0..T.sizeof];
        return bigEndianToNative!(T)( s );
    }
    
    /// Returns cell value as native date and time
    @property T as(T)() const
    if( is( T == SysTime ) )
    {
        ulong pre_time = as!(ulong)();
        // UTC because server always sends binary timestamps in UTC, not in TZ
        return SysTime( pre_time * 10, UTC() );
    }
    
    /// Returns UUID as native UUID value
    @property T as(T)() const
    if( is( T == UUID ) )
    {
        enforce( value.length == 16, "Value length isn't equal to UUID size" );
        
        UUID r;
        r.data = value;
        return r;
    }
    
    @property
    Array asArray() const
    {
        return const Array(this);
    }
}

/// Link to the cell of the answer table
const struct Array
{
    Oid OID;
    int nDims; /// Number of dimensions
    int[] dimsSize; /// Dimensions sizes info
    size_t nElems; /// Total elements
    
    private
    {
        Value cell;
        ubyte[][] elements;
        bool[] elementIsNULL;
        
        struct arrayHeader_net
        {
            ubyte[4] ndims; // number of dimensions of the array
            ubyte[4] dataoffset_ign; // offset for data, removed by libpq. may be it is conteins isNULL flag!
            ubyte[4] OID; // element type OID
        }

        struct Dim_net // network byte order
        {
            ubyte[4] dim_size; // number of elements in dimension
            ubyte[4] lbound; // unknown
        }
    }
    
    this(in Value c)
    {
        cell = c;
        enforce( cell.format == valueFormat.BINARY, "Format of the column is not binary" );
        
        arrayHeader_net* h = cast(arrayHeader_net*) cell.value.ptr;
        nDims = bigEndianToNative!int(h.ndims);
        OID = bigEndianToNative!Oid(h.OID);
        
        // TODO: here is need exception, not enforce
        enforce( nDims > 0, "Dimensions number must be more than 0" );
        
        auto ds = new int[ nDims ];
        
        // Recognize dimensions of array
        int n_elems = 1;
        for( auto i = 0; i < nDims; ++i )
        {
            Dim_net* d = (cast(Dim_net*) (h + 1)) + i;
            
            int dim_size = bigEndianToNative!int( d.dim_size );
            int lbound = bigEndianToNative!int(d.lbound);

            // FIXME: What is lbound in postgresql array reply?
            enforce( lbound == 1, "Please report if you came across this error." );
            assert( dim_size > 0 );
            
            ds[i] = dim_size;
            n_elems *= dim_size;
        }
        
        nElems = n_elems;
        dimsSize = ds.idup;
        
        auto elements = new const (ubyte)[][ nElems ];
        auto elementIsNULL = new bool[ nElems ];
        
        // Looping through all elements and fill out index of them
        auto curr_offset = arrayHeader_net.sizeof + Dim_net.sizeof * nDims;            
        for(uint i = 0; i < n_elems; ++i )
        {
            ubyte[int.sizeof] size_net;
            size_net[] = cell.value[ curr_offset .. curr_offset + size_net.sizeof ];
            uint size = bigEndianToNative!uint( size_net );
            if( size == size.max ) // NULL magic number
            {
                elementIsNULL[i] = true;
                size = 0;
            }
            else
            {
                elementIsNULL[i] = false;
            }
            curr_offset += size_net.sizeof;
            elements[i] = cell.value[curr_offset .. curr_offset + size];
            curr_offset += size;
        }
        this.elements = elements.dup;
        this.elementIsNULL = elementIsNULL.idup;
    }
    
    /// Returns Value struct by index
    Nullable!Value opIndex(int n) const
    {
        return getValue(n);
    }
    
    /// Returns Value struct
    /// Useful for multidimensional arrays
    Nullable!Value getValue( ... ) const
    {
        auto n = coords2Serial( _argptr, _arguments );
        
        Nullable!Value r;
        
        if(!elementIsNULL[n])
            r = Value( elements[n] );
        
        return r;
    }
    
    /// Value NULL checking
    bool isNULL( ... )
    {
        auto n = coords2Serial( _argptr, _arguments );
        return elementIsNULL[n];
    }
    
    private size_t coords2Serial( va_list _argptr, TypeInfo[] _arguments )
    {
        assert( _arguments.length > 0, "Number of the arguments must be more than 0" );
        
        // Variadic args parsing
        auto args = new int[ _arguments.length ];
        // TODO: here is need exception, not enforce
        enforce( nDims == args.length, "Mismatched dimensions number in arguments and server reply" );
        
        for( uint i; i < args.length; ++i )
        {
            assert( _arguments[i] == typeid(int) );
            args[i] = va_arg!(int)(_argptr);
            enforce(dimsSize[i] > args[i], "Out of range"); // TODO: here is need exception, not enforce
        }
        
        // Calculates serial number of the element
        auto inner = args.length - 1; // inner dimension
        auto element_num = args[inner]; // serial number of the element
        uint s = 1; // perpendicular to a vector which size is calculated currently
        for( auto i = inner; i > 0; --i )
        {
            s *= dimsSize[i];
            element_num += s * args[i-1];
        }
        
        assert( element_num <= nElems );
        return element_num;
    }
}

/// Notify
class notify
{
    private immutable PGnotify* n;

    this(immutable PGnotify* pgn )
    {
        n = pgn;
        cast(void) enforceEx!OutOfMemoryError(n, "Can't write notify");
    }
        
    ~this()
    {
        PQfreemem( cast(void*) n );
    }

    /// Returns notification condition name
    @property string name() { return to!string( n.relname ); }

    /// Returns notification parameter
    @property string extra() { return to!string( n.extra ); }

    /// Returns process ID of notifying server process
    @property size_t pid() { return n.be_pid; }

    nothrow invariant() 
    {
        assert( n != null );
    }
}


/// Exception
class exception : Exception
{    
    /// Exception types
    enum exceptionTypes
    {
        COLUMN_NOT_FOUND, /// Column not found
        UNDEFINED_FIXME /// Undefined, need to find and fix it
    }
    
    exceptionTypes type; /// Exception type
    
    this( exceptionTypes t, string msg )
    {
        type = t;
        super( msg, null, null );
    }
}


void _integration_test( string connParam )
{
    import std.stdio;

    // Answer properies test
    auto conn = new Connection;
	conn.connString = connParam;
    conn.connect();

    string sql_query =
    "select now() as time,  'abc'::text as field_name,   123,  456.78\n"
    "union all\n"

    "select now(),          'def'::text,                 456,  910.11\n"
    "union all\n"

    "select NULL,           'ijk_АБВГД'::text,           789,  12345.115345";

    auto e = conn.exec( sql_query );

    assert( e.rowCount == 3 );
    assert( e.columnCount == 4);
    assert( e.columnFormat(1) == valueFormat.TEXT );
    assert( e.columnFormat(2) == valueFormat.TEXT );

    assert( e[1][2].as!PGtext == "456" );
    assert( e[2][1].as!PGtext == "ijk_АБВГД" );
    assert( !e[0].isNULL(0) );
    assert( e[2].isNULL(0) );
    assert( e.columnNum( "field_name" ) == 1 );
    assert( e[1]["field_name"].as!PGtext == "def" );

    // Value properties test
    static queryArg arg;
    queryParams p;
    p.resultFormat = valueFormat.BINARY;
    p.sqlCommand = "SELECT "
        "-32761::smallint, "
        "-2147483646::integer, "
        "-9223372036854775806::bigint, "
        "-12.3456::real, "
        "-1234.56789012345::double precision, "
        "'2012-10-04 11:00:21.227803+08'::timestamp with time zone, "
        "'2012-10-04 11:00:21.227803+08'::timestamp without time zone, "
        "'2012-10-04 11:00:21.227803+00'::timestamp with time zone, "
        "'2012-10-04 11:00:21.227803+00'::timestamp without time zone, "
        "'first line\nsecond line'::text, "
        r"E'\\x44 20 72 75 6c 65 73 00 21'::bytea, " // "D rules\x00!" (ASCII)
        "array[[[1,  2, 3], "
               "[4,  5, 6]], "
               
              "[[7,  8, 9], "
              "[10, 11,12]], "
              
              "[[13,14,NULL], "
               "[16,17,18]]]::integer[], "
        "NULL, "
        "'8b9ab33a-96e9-499b-9c36-aad1fe86d640'::uuid";


    auto r = conn.exec( p );
    
    assert( r[0][0].as!PGsmallint == -32761 );
    assert( r[0][1].as!PGinteger == -2147483646 );
    assert( r[0][2].as!PGbigint == -9223372036854775806 );
    assert( r[0][3].as!PGreal == -12.3456f );
    assert( r[0][4].as!PGdouble_precision == -1234.56789012345 );
    
    assert( r[0][5].as!PGtime_stamp.toSimpleString() == "0013-Oct-05 03:00:21.227803Z" );
    assert( r[0][6].as!PGtime_stamp.toSimpleString() == "0013-Oct-05 11:00:21.227803Z" );
    assert( r[0][7].as!PGtime_stamp.toSimpleString() == "0013-Oct-05 11:00:21.227803Z" );
    assert( r[0][8].as!PGtime_stamp.toSimpleString() == "0013-Oct-05 11:00:21.227803Z" );
    
    assert( r[0][9].as!PGtext == "first line\nsecond line" );
    assert( r[0][10].as!PGbytea == [0x44, 0x20, 0x72, 0x75, 0x6c, 0x65, 0x73, 0x00, 0x21] ); // "D rules\x00!" (ASCII)
    
    auto v = r[0][11];
    assert( r.OID(11) == 1007 ); // int4 array
    auto a = v.asArray;
    assert( a.OID == 23 ); // -2 billion to 2 billion integer, 4-byte storage
    assert( a.getValue(2,1,2).as!PGinteger == 18 );
    assert( a.isNULL(2,0,2) );
    assert( !a.isNULL(2,1,2) );
    
    assert( r[0].isNULL(12) );
    
    bool isNullFlag = false;
    try
        cast(void) r[0][12].as!PGsmallint;
    catch(AssertError)
        isNullFlag = true;
    finally
        assert(isNullFlag);
    
    assert( !r[0].isNULL(9) );
    assert( r[0][13].as!PGuuid.toString() == "8b9ab33a-96e9-499b-9c36-aad1fe86d640" );
    
    // Notifies test
    auto n = conn.exec( "listen test_notify; notify test_notify" );
    assert( conn.getNextNotify.name == "test_notify" );
    
    // Async query test 1
    conn.sendQuery( "select 123; select 456; select 789" );
    while( conn.getResult() !is null ){}
    assert( conn.getResult() is null ); // removes null answer at the end

    // Async query test 2
    conn.sendQuery( p );
    while( conn.getResult() !is null ){}
    assert( conn.getResult() is null ); // removes null answer at the end
    
    // Range test
    foreach( elem; r )
    {
        import std.stdio;
        assert( elem[0].as!PGsmallint == -32761 );
    }
}
