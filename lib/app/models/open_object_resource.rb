require 'xmlrpc/client'

#TODO support name_search via search + param
#see name_search(self, cr, user, name='', args=None, operator='ilike', context=None, limit=None):
#TODO support offset, limit and order
#see def search(self, cr, user, args, offset=0, limit=None, order=None, context=None, count=False):


class OpenObjectResource < ActiveResource::Base

  # ******************** class methods ********************
  class << self

    def openerp_database=(openerp_database)
      @openerp_database = openerp_database
    end

    def all_loaded_models
      @all_loaded_models
    end


    # ******************** model class attributes assotiated to the OpenERP ir.model ********************

    def openerp_id=(openerp_id)
      @openerp_id = openerp_id
    end

    def info=(info)
      @info = info
    end

    def access_ids=(access_ids)
      @access_ids = access_ids
    end

    def name=(name)
      @name = name
    end

    def openerp_model=(openerp_model)
      @openerp_model = openerp_model
    end

    def field_ids=(field_ids)
      @field_ids = field_ids
    end

    def state=(state)
      @state = state
    end

    def class_name_from_model_key(model_key)
      model_key.split('.').collect {|name_part| name_part[0..0].upcase + name_part[1..-1]}.join
    end

    def field_defined
      @field_defined
    end

    def many2one_relations
      @many2one_relations || {}
    end

    def one2many_relations
      @one2many_relations || {}
    end

    def many2many_relations
      @many2many_relations || {}
    end

    def reload_fields_definition(force = false)
      if self != IrModel and self != IrModelFields and (force or not @field_defined)#TODO have a way to force reloading @field_ids too eventually
        unless @field_ids
           model_def = IrModel.find(:all, :domain => [['model', '=', @openerp_model]])
           @field_ids = model_def.field_id
           @access_ids = model_def.access_ids
        end
        fields = IrModelFields.find(@field_ids)
        @fields = {}
        @many2one_relations = {}
        @one2many_relations = {}
        @many2many_relations = {}
        fields.each do |field|
          case field.attributes['ttype']
          when 'many2one'
            @many2one_relations[field.attributes['name']] = field
          when 'one2many'
            @one2many_relations[field.attributes['name']] = field
          when 'many2many'
            @many2many_relations[field.attributes['name']] = field
          else
            @fields[field.attributes['name']] = field
          end
        end
        puts "#{fields.size} fields"
      end
      @field_defined = true
    end

    def define_openerp_model(arg, url, database, user_id, pass, binding)
      param = (arg.is_a? OpenObjectResource) ? arg.attributes.merge(arg.relations) : {'model' => arg}
      model_key = param['model']
      @all_loaded_models ||= []
      @all_loaded_models.push(model_key)
      model_class_name = class_name_from_model_key(model_key)
      puts "registering #{model_class_name} as a Rails ActiveResource Model wrapper for OpenObject #{model_key} model"
      definition = "
      class #{model_class_name} < OpenObjectResource
        self.site = '#{url}'
        self.user = #{user_id}
        self.password = '#{pass}'
        self.openerp_database = '#{database}'
        self.openerp_model = '#{model_key}'
        self.openerp_id = #{param['id'] || false}
        self.info = '#{param['info']}'
        self.name = '#{param['name']}'
        self.state = '#{param['state']}'
        self.field_ids = #{(param['field_id'] and '[' + param['field_id'].join(',') + ']') || false}
        self.access_ids = #{(param['access_ids'] and '[' + param['access_ids'].join(',') + ']') || false}
      end"
      eval definition, binding
    end



    # ******************** remote communication ********************

    def client
      @client ||= XMLRPC::Client.new2(@site.to_s.gsub(/\/$/,'')) #always remove trailing / to make OpenERP happy
    end


    #corresponding method for OpenERP osv.execute(self, db, uid, obj, method, *args, **kw) method
    def rpc_execute(method, *args)
      rpc_execute_with_object(@openerp_model, method, *args)
    end

    def rpc_execute_with_object(object, method, *args)
      rpc_execute_with_all(@openerp_database, @user, @password, object, method, *args)
    end

    #corresponding method for OpenERP osv.execute(self, db, uid, obj, method, *args, **kw) method
    def rpc_execute_with_all(db, uid, pass, obj, method, *args)
      client.call("execute", db, uid, pass, obj, method, *args)
    end


     #corresponding method for OpenERP osv.exec_workflow(self, db, uid, obj, method, *args)
    def rpc_exec_workflow(method, *args)
      rpc_exec_workflow_with_object(@openerp_model, method, *args)
    end

    def rpc_exec_workflow_with_object(object, method, *args)
      rpc_exec_workflow_with_all(@openerp_database, @user, @password, object, method, *args)
    end

    def rpc_exec_workflow_with_all(method, *args)
      client.call("exec_workflow", db, uid, pass, obj, method,  *args)
    end



    def load_relation(model_key, ids, *arguments)
      options = arguments.extract_options!
      relation_model_class = eval class_name_from_model_key(model_key)
      relation_model_class.send :find, ids, :fields => options[:fields] || [], :context => options[:context] || {}
    end



    # ******************** finders ********************

    private

    def find_every(options)
      domain = options[:domain]
      context = options[:context] || {}
      unless domain
        prefix_options, query_options = split_options(options[:params])
        domain = []
        query_options.each_pair do |k, v|
          domain.push [k.to_s, '=', v]
        end
      end
      ids = rpc_execute('search', domain, context)
      find_single(ids, options)
    end

    #TODO, make sense?
    def find_one
      raise "Not implemented yet, go one!"
    end

    # Find a single resource from the default URL
    def find_single(scope, options)
      fields = (options[:fields] and [options[:fields]]) || []
      context = options[:context] || {}
      prefix_options, query_options = split_options(options[:params])
      is_collection = true
      if !scope.is_a? Array
        scope = [scope]
        is_collection = false
      end
      records = rpc_execute('read', scope, *(fields + [context]))
      active_resources = []
      records.each do |record|
        r = {}
        record.each_pair do |k,v|
          r[k.to_sym] = v
        end
        active_resources << instantiate_record(r, prefix_options)
      end
      unless is_collection
        return active_resources[0]
      end
      return active_resources
    end


  end


  # ******************** instance methods ********************


  def load(attributes)
    self.class.reload_fields_definition unless self.class.field_defined
    raise ArgumentError, "expected an attributes Hash, got #{attributes.inspect}" unless attributes.is_a?(Hash)
    @prefix_options, attributes = split_options(attributes)
    attributes.each do |key, value|
      case value
        when Array
           relations[key.to_s] = value #the relation because we want the method to load the association through method missing
        when Hash
          resource = find_or_create_resource_for(key)
          @attributes[key.to_s] = resource@attributes[key.to_s].new(value)
        else
          @attributes[key.to_s] = value.dup rescue value
      end
    end

    self
  end

  #compatible with the Rails way but also supports OpenERP context
  def create(context={})
    self.class.rpc_execute('create', *(@attributes + [context]))
  end



   # ******************** fake associations like much like ActiveRecord according to the cached OpenERP data model ********************

  def relations
      @relations ||= {} and @relations
  end

  def relationnal_result(method_id, *arguments)
    self.class.reload_fields_definition unless self.class.field_defined
    if self.class.many2one_relations[method_id.to_s]
      self.class.load_relation(self.class.many2one_relations[method_id.to_s].relation, @relations[method_id.to_s][0], *arguments)
    elsif self.class.one2many_relations[method_id.to_s]
      self.class.load_relation(self.class.one2many_relations[method_id.to_s].relation, @relations[method_id.to_s], *arguments)
    elsif self.class.many2many_relations[method_id.to_s]
      self.class.load_relation(self.class.many2many_relations[method_id.to_s].relation, @relations[method_id.to_s], *arguments)
    else
      false
    end
  end

  def method_missing(method_id, *arguments)
    result = relationnal_result(method_id, *arguments)
    if result
      return result
    elsif @relations and @relations[method_id.to_s] and !self.class.many2one_relations.empty?
      #maybe the relation is inherited or could be inferred from a related field
      self.class.many2one_relations.each do |k, field|
        model = self.class.load_relation(field.relation, @relations[method_id.to_s][0], *arguments)
        result = model.relationnal_result(method_id, *arguments)
        if result
          return result
        end
      end
      super
    end
    super
  end

end