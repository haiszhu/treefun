classdef treefun2 %#ok<*PROP,*PROPLC>
%TREEFUN2   Piecewise polynomial on an adaptive quadtree.
%   TREEFUN2(F) constructs a TREEFUN2 object representing the function F on
%   the domain [-1, 1] x [-1, 1]. F may be a function handle, scalar, or
%   chebfun2 object. A TREEFUN2 is constructed by recursively subdividing
%   the domain until each piece is well approximated by a bivariate
%   polynomial of degree (N-1) x (N-1). The default is N = 16.
%
%   TREEFUN2(F, N) uses piecewise polynomials of degree (N-1) x (N-1).
%
%   TREEFUN2(F, [A B C D]) specifies a domain [A, B] x [C, D] on which the
%   TREEFUN2 is defined.
%
%   TREEFUN2(F, [A B C D], N) specifies both a degree and a domain.
%
%   TREEFUN2(F, TF) creates a TREEFUN2 approximation to F using the tree
%   structure from a previously-defined TREEFUN2. No adaptive construction
%   takes place; the function F is simply initialized on the grid inherited
%   from TF.
%
%   TREEFUN2(..., OPTS) also passes the options contained in the structure
%   OPTS. Possible options are:
%
%     OPTS.BALANCE       [true] / false
%
%     - If true, enforce that the tree is balanced (also called level
%       restricted). This condition means that the neighbors of any box
%       must be no more than one level apart from the box.
%
%     OPTS.NEIGHBORS     [true] / false
%
%     - If true, generate arrays of neighbor indices for each box. These
%     arrays are then stored in the TREEFUN2 properties flatNeighbors and
%     leafNeighbors.
%
%     OPTS.INIT          [treefun2]
%
%     - Initialize the treefun from a given tree structure.
%
%     OPTS.TOL           [1e-12]
%
%     - Tolerance for resolving the given function on each leaf.

    properties

        n = 16
        domain
        level
        height
        id
        parent
        children
        coeffs
        col
        row
        morton
        flatNeighbors
        leafNeighbors
        root = 1

    end

    methods

        function f = treefun2(varargin)

            if ( nargin < 1 )
                return
            end

            dom = [-1 1 -1 1];
            opts = struct();
            opts.balance = true;
            opts.neighbors = true;
            opts.init = [];
            opts.tol = 1e-12;
            
            if ( nargin == 2 )
                if ( isa(varargin{2}, 'treefun2') ) % TREEFUN2(F, TF)
                    % We were given the tree structure
                    f = varargin{2};
                    func = varargin{1};
                    if ( isnumeric(func) && isscalar(func) )
                        func = @(x,y) func + 0*x;
                    elseif ( isa(func, 'chebfun2') )
                        func = @(x,y) feval(func, x, y);
                    end
                    % We just need to fill in the leaf coefficients
                    L = leaves(f);
                    [xx0, yy0] = chebpts2(f.n, f.n, [0 1 0 1]);
                    for id = L(:).'
                        dom = f.domain(:,id);
                        sclx = diff(dom(1:2));
                        scly = diff(dom(3:4));
                        xx = sclx*xx0 + dom(1);
                        yy = scly*yy0 + dom(3);
                        vals = func(xx,yy);
                        f.coeffs{id} = treefun2.vals2coeffs(vals);
                    end
                    return
                elseif ( isscalar(varargin{2}) ) % TREEFUN2(F, N)
                    f.n = varargin{2};
                else
                    dom = varargin{2};           % TREEFUN2(F, [A B C D])
                end
            elseif ( nargin == 3 )
                dom = varargin{2};               % TREEFUN2(F, [A B C D], N)
                f.n = varargin{3};
            elseif ( nargin == 4 )
                dom = varargin{2};               % TREEFUN2(F, [A B C D], N, OPTS)
                f.n = varargin{3};
                opts1 = varargin{4};
                if ( isfield(opts1, 'balance') )
                    opts.balance = opts1.balance;
                end
                if ( isfield(opts1, 'neighbors') )
                    opts.neighbors = opts1.neighbors;
                end
                if ( isfield(opts1, 'init') )
                    opts.init = opts1.init;
                end
                if ( isfield(opts1, 'tol') )
                    opts.tol = opts1.tol;
                end
            elseif ( nargin == 9 )
                % TREEFUN2(DOMAIN, LEVEL, HEIGHT, ID, PARENT, CHILDREN,
                %   COEFFS, COL, ROW)
                [f.domain, f.level, f.height, f.id, f.parent, ...
                    f.children, f.coeffs, f.col, f.row] = deal(varargin{:});
                f.morton = cartesian2morton(f.col, f.row);
                f.n = size(f.coeffs{end}, 1);
                f = balance(f);
                [f.flatNeighbors, f.leafNeighbors] = generateNeighbors(f);
                return
            end

            func = varargin{1};
            if ( isnumeric(func) && isscalar(func) )
                func = @(x,y) func + 0*x;
            elseif ( isa(func, 'chebfun2') )
                func = @(x,y) feval(func, x, y);
            end

            f.domain(:,1)   = dom(:);
            f.level(1)      = 0;
            f.height(1)     = 0;
            f.id(1)         = 1;
            f.parent(1)     = 0;
            f.children(:,1) = zeros(4, 1);
            f.coeffs{1}     = [];
            f.col           = uint64(0);
            f.row           = uint64(0);

            % f = buildDepthFirst(f, func, opts.tol);
            f = buildBreadthFirst(f, func, opts.tol);
            f.morton = cartesian2morton(f.col, f.row);

            % Now do level restriction
            if ( opts.balance )
                f = balance(f);
                % f = balancef(f);
            else
                % Do a cumulative sum in reverse to correct the heights
                for k = length(f.id):-1:1
                    if ( ~isLeaf(f, k) )
                        f.height(k) = 1 + max(f.height(f.children(:,k)));
                    end
                end
            end

            if ( opts.neighbors )
                [f.flatNeighbors, f.leafNeighbors] = generateNeighbors(f);
            end

        end

        function n = numArgumentsFromSubscript(obj,s,indexingContext) %#ok<INUSD>
        %NUMARGUMENTSFROMSUBSCRIPT   Number of arguments for customized indexing methods.
        %   Overloading NUMEL() gives the wrong NARGOUT for SUBSREF().
        %   Defining this function fixes it.
        %
        % See also NUMEL, NARGOUT, SUBSREF.
            n = 1;
        end

    end

    methods ( Access = private )

        f = refineBox(f, id);

        function f = buildBreadthFirst(f, func, tol)

            % Note: the length changes at each iteration here
            id = 1;
            while ( id <= length(f.id) )
                [resolved, coeffs] = isResolved(func, f.domain(:,id), f.n, tol);
                if ( resolved )
                    f.coeffs{id} = coeffs;
                    f.height(id) = 0;
                else
                    % Split into four child boxes
                    f = refineBox(f, id);
                    f.height(id) = 1;
                end
                id = id + 1;
            end

            % Do a cumulative sum in reverse to correct the heights
            for k = length(f.id):-1:1
                if ( ~isLeaf(f, k) )
                    %f.height(k) = f.height(k) + max(f.height(f.children(:,k)));
                    f.height(k) = 1 + max(f.height(f.children(:,k)));
                end
            end

        end
        
        function f = buildDepthFirst(f, func, id, level, tol)

            if ( nargin == 2 )
                id = 1;
                level = 0;
            end

            f.level(id) = level;
            f.height(id) = 0;

            [resolved, coeffs] = isResolved(func, f.domain(:,id), f.n, tol);

            if ( resolved )
                f.coeffs{id} = coeffs;
            else
                % Split into four child boxes
                f = refineBox(f, id);

                % Recurse
                f = buildDepthFirst(f, func, f.children(1,id), level+1, tol);
                f = buildDepthFirst(f, func, f.children(2,id), level+1, tol);
                f = buildDepthFirst(f, func, f.children(3,id), level+1, tol);
                f = buildDepthFirst(f, func, f.children(4,id), level+1, tol);

                % Set height
                f.height(id) = 1 + max(f.height(f.children(:,id)));
            end

        end

    end

    methods ( Static )

        u = poisson(f, isource);
        coeffs = vals2coeffs(vals);
        vals = coeffs2vals(coeffs);
        vals = coeffs2refvals(coeffs);
        refvals = chebvals2refvals(chebvals);
        checkvals = coeffs2checkvals(coeffs,x,y);

    end

end

function [resolved, coeffs] = isResolved(f, dom, n, tol)

persistent xx0 yy0 xxx0 yyy0 nstored

nalias = 2*n;
nrefpts = 2*n; % Sample at equispaced points to test error

if ( isempty(xx0) || isempty(xxx0) || n ~= nstored )
    nstored = n;
    [xx0, yy0] = chebpts2(nalias, nalias, [0 1 0 1]);
    [xxx0, yyy0] = meshgrid(linspace(0, 1, nrefpts));
end
sclx = diff(dom(1:2));
scly = diff(dom(3:4));
xx = sclx*xx0 + dom(1); xxx = sclx*xxx0 + dom(1);
yy = scly*yy0 + dom(3); yyy = scly*yyy0 + dom(3);

vals = f(xx,yy);
coeffs = treefun2.vals2coeffs(vals);
coeffs = coeffs(1:n,1:n);
Ex = sum(abs(coeffs(end-1:end,:)), 'all') / (2*n);
Ey = sum(abs(coeffs(:,end-1:end)), 'all') / (2*n);
err_cfs = (Ex + Ey) / 2;

% F = f(xxx,yyy);
% G = coeffs2refvals(coeffs);
% err_vals = max(abs(F(:) - G(:)));

err = err_cfs;
%err = min(err_cfs, err_vals);
h = sclx;
eta = 0;

vmax = max(abs(vals(:)));
resolved = ( err * h^eta < tol * max(vmax, 1) );

end
